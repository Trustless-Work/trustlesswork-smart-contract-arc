// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISingleReleaseEscrow} from "./ISingleReleaseEscrow.sol";

interface ISingleReleaseEscrowFactory {
    struct AddressBalance {
        address escrow;
        uint256 balance;
        uint8 tokenDecimals;
    }

    error ZeroAddress();
    error TooManyEscrowsRequested();

    event EscrowCreated(
        address indexed escrow, address indexed creator, string engagementId, address admin, bytes32 salt
    );
    event TrustlessWorkFeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    function implementation() external view returns (address);

    function trustlessWorkFeeRecipient() external view returns (address);

    function createEscrow(bytes32 salt, ISingleReleaseEscrow.Escrow calldata escrowProperties)
        external
        returns (address escrow);

    function predictEscrowAddress(address creator, bytes32 salt) external view returns (address);

    function getMultipleEscrowBalances(address[] calldata escrows) external view returns (AddressBalance[] memory);
}
