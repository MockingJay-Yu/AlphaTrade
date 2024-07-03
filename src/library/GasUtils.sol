// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../data/DataStore.sol";
import "../data/Keys.sol";
import "./deposit/Deposit.sol";
import "./Precision.sol";
import "../order/Order.sol";

library GasUtils {
    using Deposit for Deposit.Props;

    // @dev the estimated gas limit for deposits
    // @param dataStore DataStore
    // @param deposit the deposit to estimate the gas limit for
    function estimateExecuteDepositGasLimit(DataStore dataStore, Deposit.Props memory deposit)
        internal
        view
        returns (uint256)
    {
        uint256 gasPerSwap = dataStore.getUint(Keys.singleSwapGasLimitKey());
        uint256 swapCount = deposit.longTokenSwapPath().length + deposit.shortTokenSwapPath().length;
        uint256 gasForSwaps = swapCount * gasPerSwap;

        if (deposit.initialLongTokenAmount() == 0 || deposit.initialShortTokenAmount() == 0) {
            return dataStore.getUint(Keys.depositGasLimitKey(true)) + deposit.callbackGasLimit() + gasForSwaps;
        }

        return dataStore.getUint(Keys.depositGasLimitKey(false)) + deposit.callbackGasLimit() + gasForSwaps;
    }

    // @dev validate that the provided executionFee is sufficient based on the estimatedGasLimit
    // @param dataStore DataStore
    // @param estimatedGasLimit the estimated gas limit
    // @param executionFee the execution fee provided
    function validateExecutionFee(DataStore dataStore, uint256 estimatedGasLimit, uint256 executionFee) internal view {
        uint256 gasLimit = adjustGasLimitForEstimate(dataStore, estimatedGasLimit);
        uint256 minExecutionFee = gasLimit * tx.gasprice;
        if (executionFee < minExecutionFee) {
            revert Errors.InsufficientExecutionFee(minExecutionFee, executionFee);
        }
    }

    // @dev adjust the estimated gas limit to help ensure the execution fee is sufficient during
    // the actual execution
    // @param dataStore DataStore
    // @param estimatedGasLimit the estimated gas limit
    function adjustGasLimitForEstimate(DataStore dataStore, uint256 estimatedGasLimit)
        internal
        view
        returns (uint256)
    {
        uint256 baseGasLimit = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_BASE_AMOUNT);
        uint256 multiplierFactor = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimit = baseGasLimit + Precision.applyFactor(estimatedGasLimit, multiplierFactor);
        return gasLimit;
    }

    // @dev the estimated gas limit for orders
    // @param dataStore DataStore
    // @param order the order to estimate the gas limit for
    function estimateExecuteOrderGasLimit(DataStore dataStore, Order.Props memory order)
        internal
        view
        returns (uint256)
    {
        if (BaseOrderUtils.isIncreaseOrder(order.orderType())) {
            return estimateExecuteIncreaseOrderGasLimit(dataStore, order);
        }

        if (BaseOrderUtils.isDecreaseOrder(order.orderType())) {
            return estimateExecuteDecreaseOrderGasLimit(dataStore, order);
        }

        if (BaseOrderUtils.isSwapOrder(order.orderType())) {
            return estimateExecuteSwapOrderGasLimit(dataStore, order);
        }

        revert Errors.UnsupportedOrderType();
    }

    // @dev the estimated gas limit for increase orders
    // @param dataStore DataStore
    // @param order the order to estimate the gas limit for
    function estimateExecuteIncreaseOrderGasLimit(DataStore dataStore, Order.Props memory order)
        internal
        view
        returns (uint256)
    {
        uint256 gasPerSwap = dataStore.getUint(Keys.singleSwapGasLimitKey());
        return dataStore.getUint(Keys.increaseOrderGasLimitKey()) + gasPerSwap * order.swapPath().length
            + order.callbackGasLimit();
    }

    // @dev the estimated gas limit for decrease orders
    // @param dataStore DataStore
    // @param order the order to estimate the gas limit for
    function estimateExecuteDecreaseOrderGasLimit(DataStore dataStore, Order.Props memory order)
        internal
        view
        returns (uint256)
    {
        uint256 gasPerSwap = dataStore.getUint(Keys.singleSwapGasLimitKey());
        uint256 swapCount = order.swapPath().length;
        if (order.decreasePositionSwapType() != Order.DecreasePositionSwapType.NoSwap) {
            swapCount += 1;
        }

        return dataStore.getUint(Keys.decreaseOrderGasLimitKey()) + gasPerSwap * swapCount + order.callbackGasLimit();
    }

    // @dev the estimated gas limit for swap orders
    // @param dataStore DataStore
    // @param order the order to estimate the gas limit for
    function estimateExecuteSwapOrderGasLimit(DataStore dataStore, Order.Props memory order)
        internal
        view
        returns (uint256)
    {
        uint256 gasPerSwap = dataStore.getUint(Keys.singleSwapGasLimitKey());
        return dataStore.getUint(Keys.swapOrderGasLimitKey()) + gasPerSwap * order.swapPath().length
            + order.callbackGasLimit();
    }
}
