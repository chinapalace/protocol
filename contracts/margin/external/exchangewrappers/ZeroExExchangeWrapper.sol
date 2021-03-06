/*

    Copyright 2018 dYdX Trading Inc.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity 0.4.24;
pragma experimental "v0.5.0";

import { SafeMath } from "zeppelin-solidity/contracts/math/SafeMath.sol";
import { HasNoContracts } from "zeppelin-solidity/contracts/ownership/HasNoContracts.sol";
import { HasNoEther } from "zeppelin-solidity/contracts/ownership/HasNoEther.sol";
import { ZeroExExchangeInterface } from "../../../external/0x/ZeroExExchangeInterface.sol";
import { MathHelpers } from "../../../lib/MathHelpers.sol";
import { TokenInteract } from "../../../lib/TokenInteract.sol";
import { ExchangeWrapper } from "../../interfaces/ExchangeWrapper.sol";


/**
 * @title ZeroExExchangeWrapper
 * @author dYdX
 *
 * dYdX ExchangeWrapper to interface with 0x Version 1
 */
contract ZeroExExchangeWrapper is
    HasNoEther,
    HasNoContracts,
    ExchangeWrapper
{
    using SafeMath for uint256;

    // ============ Structs ============

    struct Order {
        address maker;
        address taker;
        address feeRecipient;
        uint256 makerTokenAmount;
        uint256 takerTokenAmount;
        uint256 makerFee;
        uint256 takerFee;
        uint256 expirationUnixTimestampSec;
        uint256 salt;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // ============ State Variables ============

    address public ZERO_EX_EXCHANGE;
    address public ZERO_EX_PROXY;
    address public ZRX;

    // ============ Constructor ============

    constructor(
        address margin,
        address dydxProxy,
        address zeroExExchange,
        address zeroExProxy,
        address zrxToken
    )
        public
        ExchangeWrapper(margin, dydxProxy)
    {
        ZERO_EX_EXCHANGE = zeroExExchange;
        ZERO_EX_PROXY = zeroExProxy;
        ZRX = zrxToken;

        // The ZRX token does not decrement allowance if set to MAX_UINT
        // therefore setting it once to the maximum amount is sufficient
        // NOTE: this is *not* standard behavior for an ERC20, so do not rely on it for other tokens
        TokenInteract.approve(ZRX, ZERO_EX_PROXY, MathHelpers.maxUint256());
    }

    // ============ Margin-Only Functions ============

    function exchange(
        address makerToken,
        address takerToken,
        address tradeOriginator,
        uint256 requestedFillAmount,
        bytes orderData
    )
        external
        onlyMargin
        returns (uint256)
    {
        Order memory order = parseOrder(orderData);

        require(
            requestedFillAmount <= order.takerTokenAmount,
            "ZeroExExchangeWrapper#exchangeImpl: Requested fill amount larger than order size"
        );

        transferTakerFee(
            order,
            tradeOriginator,
            requestedFillAmount
        );

        ensureAllowance(
            takerToken,
            ZERO_EX_PROXY,
            requestedFillAmount
        );

        assert(TokenInteract.balanceOf(takerToken, address(this)) >= requestedFillAmount);

        uint256 receivedMakerTokenAmount = doTrade(
            order,
            makerToken,
            takerToken,
            requestedFillAmount
        );

        ensureAllowance(
            makerToken,
            DYDX_PROXY,
            receivedMakerTokenAmount
        );

        return receivedMakerTokenAmount;
    }

    function getExchangeCost(
        address /* makerToken */,
        address /* takerToken */,
        uint256 desiredMakerToken,
        bytes orderData
    )
        external
        view
        returns (uint256)
    {
        Order memory order = parseOrder(orderData);

        return MathHelpers.getPartialAmountRoundedUp(
            order.takerTokenAmount,
            order.makerTokenAmount,
            desiredMakerToken
        );
    }

    // ============ Private Functions ============

    function transferTakerFee(
        Order order,
        address tradeOriginator,
        uint256 requestedFillAmount
    )
        private
    {
        if (order.feeRecipient == address(0)) {
            return;
        }

        uint256 takerFee = MathHelpers.getPartialAmount(
            requestedFillAmount,
            order.takerTokenAmount,
            order.takerFee
        );

        TokenInteract.transferFrom(
            ZRX,
            tradeOriginator,
            address(this),
            takerFee
        );
    }

    function doTrade(
        Order order,
        address makerToken,
        address takerToken,
        uint256 requestedFillAmount
    )
        private
        returns (uint256)
    {
        uint256 filledTakerTokenAmount = ZeroExExchangeInterface(ZERO_EX_EXCHANGE).fillOrder(
            [
                order.maker,
                order.taker,
                makerToken,
                takerToken,
                order.feeRecipient
            ],
            [
                order.makerTokenAmount,
                order.takerTokenAmount,
                order.makerFee,
                order.takerFee,
                order.expirationUnixTimestampSec,
                order.salt
            ],
            requestedFillAmount,
            true,
            order.v,
            order.r,
            order.s
        );

        require(
            filledTakerTokenAmount == requestedFillAmount,
            "ZeroExExchangeWrapper#doTrade: Could not fill requested amount"
        );

        uint256 receivedMakerTokenAmount = MathHelpers.getPartialAmount(
            filledTakerTokenAmount,
            order.takerTokenAmount,
            order.makerTokenAmount
        );

        return receivedMakerTokenAmount;
    }

    function ensureAllowance(
        address token,
        address spender,
        uint256 requiredAmount
    )
        private
    {
        if (TokenInteract.allowance(token, address(this), spender) >= requiredAmount) {
            return;
        }

        TokenInteract.approve(
            token,
            spender,
            MathHelpers.maxUint256()
        );
    }

    // ============ Parsing Functions ============

    /**
     * Accepts a byte array with each variable padded to 32 bytes
     */
    function parseOrder(
        bytes orderData
    )
        private
        pure
        returns (Order memory)
    {
        Order memory order;

        /**
         * Total: 384 bytes
         * mstore stores 32 bytes at a time, so go in increments of 32 bytes
         *
         * NOTE: The first 32 bytes in an array stores the length, so we start reading from 32
         */
        /* solium-disable-next-line */
        assembly {
            mstore(order,           mload(add(orderData, 32)))  // maker
            mstore(add(order, 32),  mload(add(orderData, 64)))  // taker
            mstore(add(order, 64),  mload(add(orderData, 96)))  // feeRecipient
            mstore(add(order, 96),  mload(add(orderData, 128))) // makerTokenAmount
            mstore(add(order, 128), mload(add(orderData, 160))) // takerTokenAmount
            mstore(add(order, 160), mload(add(orderData, 192))) // makerFee
            mstore(add(order, 192), mload(add(orderData, 224))) // takerFee
            mstore(add(order, 224), mload(add(orderData, 256))) // expirationUnixTimestampSec
            mstore(add(order, 256), mload(add(orderData, 288))) // salt
            mstore(add(order, 288), mload(add(orderData, 320))) // v
            mstore(add(order, 320), mload(add(orderData, 352))) // r
            mstore(add(order, 352), mload(add(orderData, 384))) // s
        }

        return order;
    }
}
