// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @notice Arc-only entry point for callers that can only pass flat arguments.
/// @dev Circle CLI agent wallets (`circle wallet execute`, CLI 1.1.4) encode
/// `uint256`, `address`, `bytes32`, `string` and `bytes` arguments, but not
/// arrays or tuples, so they cannot call `createEscrow`, `approveMilestones` or
/// `resolveDispute` directly. They pass the ABI-encoded call as `bytes` instead.
/// Delegatecalling into this same contract keeps `msg.sender`, the storage and
/// the reentrancy lock, so every check runs exactly as in a direct call (the
/// pattern behind OpenZeppelin's `Multicall`).
abstract contract CalldataExecutor {
    /// @param data ABI-encoded call to one of this contract's own functions.
    /// @return The call's ABI-encoded return data. Reverts bubble up unchanged.
    function execute(bytes calldata data) external returns (bytes memory) {
        return Address.functionDelegateCall(address(this), data);
    }
}
