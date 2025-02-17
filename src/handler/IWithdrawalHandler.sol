// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../withdrawal/WithdrawalUtils.sol";

interface IWithdrawalHandler {
    function createWithdrawal(address account, WithdrawalUtils.CreateWithdrawalParams calldata params)
        external
        returns (bytes32);
    function cancelWithdrawal(bytes32 key) external;
}
