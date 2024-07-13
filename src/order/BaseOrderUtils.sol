// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./Order.sol";
import "../market/Market.sol";

import "../data/DataStore.sol";
import "../event/EventEmitter.sol";
import "../referral/IReferralStorage.sol";

import "../order/OrderVault.sol";

import "../oracle/Oracle.sol";
import "../swap/SwapHandler.sol";
import "../position/Position.sol";

// @title Order
// @dev Library for common order functions used in OrderUtils, IncreaseOrderUtils
// DecreaseOrderUtils, SwapOrderUtils
library BaseOrderUtils {
    using SafeCast for int256;
    using SafeCast for uint256;

    using Order for Order.Props;
    using Price for Price.Props;

    // @dev ExecuteOrderParams struct used in executeOrder to avoid stack
    // too deep errors
    //
    // @param contracts ExecuteOrderParamsContracts
    // @param key the key of the order to execute
    // @param order the order to execute
    // @param swapPathMarkets the market values of the markets in the swapPath
    // @param minOracleTimestamp the min oracle timestamp
    // @param maxOracleTimestamp the max oracle timestamp
    // @param market market values of the trading market
    // @param keeper the keeper sending the transaction
    // @param startingGas the starting gas
    // @param secondaryOrderType the secondary order type
    struct ExecuteOrderParams {
        ExecuteOrderParamsContracts contracts;
        bytes32 key;
        Order.Props order;
        Market.Props[] swapPathMarkets;
        uint256 minOracleTimestamp;
        uint256 maxOracleTimestamp;
        Market.Props market;
        address keeper;
        uint256 startingGas;
        Order.SecondaryOrderType secondaryOrderType;
    }

    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param orderVault OrderVault
    // @param oracle Oracle
    // @param swapHandler SwapHandler
    // @param referralStorage IReferralStorage
    struct ExecuteOrderParamsContracts {
        DataStore dataStore;
        EventEmitter eventEmitter;
        OrderVault orderVault;
        Oracle oracle;
        SwapHandler swapHandler;
        IReferralStorage referralStorage;
    }

    struct GetExecutionPriceCache {
        uint256 price;
        uint256 executionPrice;
        int256 adjustedPriceImpactUsd;
    }

    // @dev check if an orderType is a market order
    // @param orderType the order type
    // @return whether an orderType is a market order
    function isMarketOrder(Order.OrderType orderType) internal pure returns (bool) {
        // a liquidation order is not considered as a market order
        return orderType == Order.OrderType.MarketSwap || orderType == Order.OrderType.MarketIncrease
            || orderType == Order.OrderType.MarketDecrease;
    }

    // @dev check if an orderType is a limit order
    // @param orderType the order type
    // @return whether an orderType is a limit order
    function isLimitOrder(Order.OrderType orderType) internal pure returns (bool) {
        return orderType == Order.OrderType.LimitSwap || orderType == Order.OrderType.LimitIncrease
            || orderType == Order.OrderType.LimitDecrease;
    }

    // @dev check if an orderType is a swap order
    // @param orderType the order type
    // @return whether an orderType is a swap order
    function isSwapOrder(Order.OrderType orderType) internal pure returns (bool) {
        return orderType == Order.OrderType.MarketSwap || orderType == Order.OrderType.LimitSwap;
    }

    // @dev check if an orderType is a position order
    // @param orderType the order type
    // @return whether an orderType is a position order
    function isPositionOrder(Order.OrderType orderType) internal pure returns (bool) {
        return isIncreaseOrder(orderType) || isDecreaseOrder(orderType);
    }

    // @dev check if an orderType is an increase order
    // @param orderType the order type
    // @return whether an orderType is an increase order
    function isIncreaseOrder(Order.OrderType orderType) internal pure returns (bool) {
        return orderType == Order.OrderType.MarketIncrease || orderType == Order.OrderType.LimitIncrease;
    }

    // @dev check if an orderType is a decrease order
    // @param orderType the order type
    // @return whether an orderType is a decrease order
    function isDecreaseOrder(Order.OrderType orderType) internal pure returns (bool) {
        return orderType == Order.OrderType.MarketDecrease || orderType == Order.OrderType.LimitDecrease
            || orderType == Order.OrderType.StopLossDecrease || orderType == Order.OrderType.Liquidation;
    }

    // @dev check if an orderType is a liquidation order
    // @param orderType the order type
    // @return whether an orderType is a liquidation order
    function isLiquidationOrder(Order.OrderType orderType) internal pure returns (bool) {
        return orderType == Order.OrderType.Liquidation;
    }

    // @dev validate the price for increase / decrease orders based on the triggerPrice
    // the acceptablePrice for increase / decrease orders is validated in getExecutionPrice
    //
    // it is possible to update the oracle to support a primaryPrice and a secondaryPrice
    // which would allow for stop-loss orders to be executed at exactly the triggerPrice
    //
    // however, this may lead to gaming issues, an example:
    // - the current price is $2020
    // - a user has a long position and creates a stop-loss decrease order for < $2010
    // - if the order has a swap from ETH to USDC and the user is able to cause the order
    // to be frozen / unexecutable by manipulating state or otherwise
    // - then if price decreases to $2000, and the user is able to manipulate state such that
    // the order becomes executable with $2010 being used as the price instead
    // - then the user would be able to perform the swap at a higher price than should possible
    //
    // additionally, using the exact order's triggerPrice could lead to gaming issues during times
    // of volatility due to users setting tight stop-losses to minimize loss while betting on a
    // directional price movement, fees and price impact should help a bit with this, but there
    // still may be some probability of success
    //
    // the order keepers can use the closest oracle price to the triggerPrice for execution, which
    // should lead to similar order execution prices with reduced gaming risks
    //
    // if an order is frozen, the frozen order keepers should use the most recent price for order
    // execution instead
    //
    // @param oracle Oracle
    // @param indexToken the index token
    // @param orderType the order type
    // @param triggerPrice the order's triggerPrice
    // @param isLong whether the order is for a long or short
    function validateOrderTriggerPrice(
        Oracle oracle,
        address indexToken,
        Order.OrderType orderType,
        uint256 triggerPrice,
        bool isLong
    ) internal view {
        //只有LimitIncrease，LimitDecrease，StopLossDecrease才会进行触发价格验证
        //LimitSwap不需要触发价格验证，它只会在限定的价格范围内执行
        if (isSwapOrder(orderType) || isMarketOrder(orderType) || isLiquidationOrder(orderType)) {
            return;
        }

        Price.Props memory primaryPrice = oracle.getPrimaryPrice(indexToken);

        if (orderType == Order.OrderType.LimitIncrease) {
            //对于限价加仓来说，如果是做多，只有最高价格跌倒触发价格执行，如果是做空，只有最低价格涨到触发价格执行
            //对于用户来说，这个价格是他们认为足够低的一个价格，当市场价格到达这个价格，执行买入，符合低买原则
            bool ok = isLong ? primaryPrice.max <= triggerPrice : primaryPrice.min >= triggerPrice;

            if (!ok) {
                revert Errors.InvalidOrderPrices(primaryPrice.min, primaryPrice.max, triggerPrice, uint256(orderType));
            }

            return;
        }

        if (orderType == Order.OrderType.LimitDecrease) {
            //对于限价减仓来说，如果是做多，只有最低价格涨到触发价格执行，如果是做空，只有最高价格跌到触发价格执行
            //对于用户来说，这个价格是他们认为足够高的一个价格，当市场价格到达这个价格，执行卖出，符合高卖原则
            bool ok = isLong ? primaryPrice.min >= triggerPrice : primaryPrice.max <= triggerPrice;

            if (!ok) {
                revert Errors.InvalidOrderPrices(primaryPrice.min, primaryPrice.max, triggerPrice, uint256(orderType));
            }

            return;
        }

        if (orderType == Order.OrderType.StopLossDecrease) {
            //对于止损单来说，当市场价格到达某个水平便自动执行卖出操作，目的限制用户的潜在损失
            //如果是做多，当最低价格跌倒触发价格时执行，如果是做空，当最高价格涨到触发价格时执行
            bool ok = isLong ? primaryPrice.min <= triggerPrice : primaryPrice.max >= triggerPrice;

            if (!ok) {
                revert Errors.InvalidOrderPrices(primaryPrice.min, primaryPrice.max, triggerPrice, uint256(orderType));
            }

            return;
        }

        revert Errors.UnsupportedOrderType(uint256(orderType));
    }

    function getExecutionPriceForIncrease(
        uint256 sizeDeltaUsd,
        uint256 sizeDeltaInTokens,
        uint256 acceptablePrice,
        bool isLong
    ) internal pure returns (uint256) {
        if (sizeDeltaInTokens == 0) {
            revert Errors.EmptySizeDeltaInTokens();
        }

        uint256 executionPrice = sizeDeltaUsd / sizeDeltaInTokens;

        // increase order:
        //     - long: executionPrice should be smaller than acceptablePrice
        //     - short: executionPrice should be larger than acceptablePrice
        if ((isLong && executionPrice <= acceptablePrice) || (!isLong && executionPrice >= acceptablePrice)) {
            return executionPrice;
        }

        // the validateOrderTriggerPrice function should have validated if the price fulfills
        // the order's trigger price
        //
        // for increase orders, the negative price impact is not capped
        //
        // for both increase and decrease orders, if it is due to price impact that the
        // order cannot be fulfilled then the order should be frozen
        //
        // this is to prevent gaming by manipulation of the price impact value
        //
        // usually it should be costly to game the price impact value
        // however, for certain cases, e.g. a user already has a large position opened
        // the user may create limit orders that would only trigger after they close
        // their position, this gives the user the option to cancel the pending order if
        // prices do not move in their favour or to close their position and let the order
        // execute if prices move in their favour
        //
        // it may also be possible for users to prevent the execution of orders from other users
        // by manipulating the price impact, though this should be costly
        revert Errors.OrderNotFulfillableAtAcceptablePrice(executionPrice, acceptablePrice);
    }

    function getExecutionPriceForDecrease(
        Price.Props memory indexTokenPrice,
        uint256 positionSizeInUsd,
        uint256 positionSizeInTokens,
        uint256 sizeDeltaUsd,
        int256 priceImpactUsd,
        uint256 acceptablePrice,
        bool isLong
    ) internal pure returns (uint256) {
        GetExecutionPriceCache memory cache;

        // decrease order:
        //     - long: use the smaller price
        //     - short: use the larger price
        cache.price = indexTokenPrice.pickPrice(!isLong);
        cache.executionPrice = cache.price;

        // using closing of long positions as an example
        // realized pnl is calculated as totalPositionPnl * sizeDeltaInTokens / position.sizeInTokens
        // totalPositionPnl: position.sizeInTokens * executionPrice - position.sizeInUsd
        // sizeDeltaInTokens: position.sizeInTokens * sizeDeltaUsd / position.sizeInUsd
        // realized pnl: (position.sizeInTokens * executionPrice - position.sizeInUsd) * (position.sizeInTokens * sizeDeltaUsd / position.sizeInUsd) / position.sizeInTokens
        // realized pnl: (position.sizeInTokens * executionPrice - position.sizeInUsd) * (sizeDeltaUsd / position.sizeInUsd)
        // priceImpactUsd should adjust the execution price such that:
        // [(position.sizeInTokens * executionPrice - position.sizeInUsd) * (sizeDeltaUsd / position.sizeInUsd)] -
        // [(position.sizeInTokens * price - position.sizeInUsd) * (sizeDeltaUsd / position.sizeInUsd)] = priceImpactUsd
        //
        // (position.sizeInTokens * executionPrice - position.sizeInUsd) - (position.sizeInTokens * price - position.sizeInUsd)
        // = priceImpactUsd / (sizeDeltaUsd / position.sizeInUsd)
        // = priceImpactUsd * position.sizeInUsd / sizeDeltaUsd
        //
        // position.sizeInTokens * executionPrice - position.sizeInTokens * price = priceImpactUsd * position.sizeInUsd / sizeDeltaUsd
        // position.sizeInTokens * (executionPrice - price) = priceImpactUsd * position.sizeInUsd / sizeDeltaUsd
        // executionPrice - price = (priceImpactUsd * position.sizeInUsd) / (sizeDeltaUsd * position.sizeInTokens)
        // executionPrice = price + (priceImpactUsd * position.sizeInUsd) / (sizeDeltaUsd * position.sizeInTokens)
        // executionPrice = price + (priceImpactUsd / sizeDeltaUsd) * (position.sizeInUsd / position.sizeInTokens)
        // executionPrice = price + (priceImpactUsd * position.sizeInUsd / position.sizeInTokens) / sizeDeltaUsd
        //
        // e.g. if price is $2000, sizeDeltaUsd is $5000, priceImpactUsd is -$1000, position.sizeInUsd is $10,000, position.sizeInTokens is 5
        // executionPrice = 2000 + (-1000 * 10,000 / 5) / 5000 = 1600
        // realizedPnl based on price, without price impact: 0
        // realizedPnl based on executionPrice, with price impact: (5 * 1600 - 10,000) * (5 * 5000 / 10,000) / 5 => -1000

        // a positive adjustedPriceImpactUsd would decrease the executionPrice
        // a negative adjustedPriceImpactUsd would increase the executionPrice

        // for increase orders, the adjustedPriceImpactUsd is added to the divisor
        // a positive adjustedPriceImpactUsd would increase the divisor and decrease the executionPrice
        // increase long order:
        //      - if price impact is positive, adjustedPriceImpactUsd should be positive, to decrease the executionPrice
        //      - if price impact is negative, adjustedPriceImpactUsd should be negative, to increase the executionPrice
        // increase short order:
        //      - if price impact is positive, adjustedPriceImpactUsd should be negative, to increase the executionPrice
        //      - if price impact is negative, adjustedPriceImpactUsd should be positive, to decrease the executionPrice

        // for decrease orders, the adjustedPriceImpactUsd adjusts the numerator
        // a positive adjustedPriceImpactUsd would increase the divisor and increase the executionPrice
        // decrease long order:
        //      - if price impact is positive, adjustedPriceImpactUsd should be positive, to increase the executionPrice
        //      - if price impact is negative, adjustedPriceImpactUsd should be negative, to decrease the executionPrice
        // decrease short order:
        //      - if price impact is positive, adjustedPriceImpactUsd should be negative, to decrease the executionPrice
        //      - if price impact is negative, adjustedPriceImpactUsd should be positive, to increase the executionPrice
        // adjust price by price impact
        if (sizeDeltaUsd > 0 && positionSizeInTokens > 0) {
            cache.adjustedPriceImpactUsd = isLong ? priceImpactUsd : -priceImpactUsd;

            if (cache.adjustedPriceImpactUsd < 0 && (-cache.adjustedPriceImpactUsd).toUint256() > sizeDeltaUsd) {
                revert Errors.PriceImpactLargerThanOrderSize(cache.adjustedPriceImpactUsd, sizeDeltaUsd);
            }

            int256 adjustment = Precision.mulDiv(positionSizeInUsd, cache.adjustedPriceImpactUsd, positionSizeInTokens)
                / sizeDeltaUsd.toInt256();
            int256 _executionPrice = cache.price.toInt256() + adjustment;

            if (_executionPrice < 0) {
                revert Errors.NegativeExecutionPrice(
                    _executionPrice, cache.price, positionSizeInUsd, cache.adjustedPriceImpactUsd, sizeDeltaUsd
                );
            }

            cache.executionPrice = _executionPrice.toUint256();
        }

        // decrease order:
        //     - long: executionPrice should be larger than acceptablePrice
        //     - short: executionPrice should be smaller than acceptablePrice
        if ((isLong && cache.executionPrice >= acceptablePrice) || (!isLong && cache.executionPrice <= acceptablePrice))
        {
            return cache.executionPrice;
        }

        // the validateOrderTriggerPrice function should have validated if the price fulfills
        // the order's trigger price
        //
        // for decrease orders, the price impact should already be capped, so if the user
        // had set an acceptable price within the range of the capped price impact, then
        // the order should be fulfillable at the acceptable price
        //
        // for increase orders, the negative price impact is not capped
        //
        // for both increase and decrease orders, if it is due to price impact that the
        // order cannot be fulfilled then the order should be frozen
        //
        // this is to prevent gaming by manipulation of the price impact value
        //
        // usually it should be costly to game the price impact value
        // however, for certain cases, e.g. a user already has a large position opened
        // the user may create limit orders that would only trigger after they close
        // their position, this gives the user the option to cancel the pending order if
        // prices do not move in their favour or to close their position and let the order
        // execute if prices move in their favour
        //
        // it may also be possible for users to prevent the execution of orders from other users
        // by manipulating the price impact, though this should be costly
        revert Errors.OrderNotFulfillableAtAcceptablePrice(cache.executionPrice, acceptablePrice);
    }

    // @dev validate that an order exists
    // @param order the order to check
    function validateNonEmptyOrder(Order.Props memory order) internal pure {
        if (order.account() == address(0)) {
            revert Errors.EmptyOrder();
        }

        if (order.sizeDeltaUsd() == 0 && order.initialCollateralDeltaAmount() == 0) {
            revert Errors.EmptyOrder();
        }
    }

    function getPositionKey(Order.Props memory order) internal pure returns (bytes32) {
        if (isDecreaseOrder(order.orderType())) {
            return
                Position.getPositionKey(order.account(), order.market(), order.initialCollateralToken(), order.isLong());
        }

        revert Errors.UnsupportedOrderType(uint256(order.orderType()));
    }
}
