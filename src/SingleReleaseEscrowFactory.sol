// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ISingleReleaseEscrow} from "./interfaces/ISingleReleaseEscrow.sol";
import {ISingleReleaseEscrowFactory} from "./interfaces/ISingleReleaseEscrowFactory.sol";
import {SingleReleaseEscrow} from "./SingleReleaseEscrow.sol";
import {CalldataExecutor} from "./utils/CalldataExecutor.sol";

/// @notice EVM counterpart of the Soroban deployer (`tw_new_single_release_escrow`).
/// Deploys one EIP-1167 clone per escrow and initializes it in the same call, so
/// no one can front-run `initialize`. The fixed `implementation` plays the role
/// of the Soroban approved WASM hash.
contract SingleReleaseEscrowFactory is ISingleReleaseEscrowFactory, Ownable2Step, CalldataExecutor {
    uint256 private constant MAX_ESCROWS = 20;

    address public immutable implementation;
    address public trustlessWorkFeeRecipient;

    constructor(address initialOwner, address feeRecipient) Ownable(initialOwner) {
        if (feeRecipient == address(0)) revert ZeroAddress();
        implementation = address(new SingleReleaseEscrow(address(this)));
        trustlessWorkFeeRecipient = feeRecipient;
        emit TrustlessWorkFeeRecipientUpdated(address(0), feeRecipient);
    }

    function setTrustlessWorkFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit TrustlessWorkFeeRecipientUpdated(trustlessWorkFeeRecipient, newRecipient);
        trustlessWorkFeeRecipient = newRecipient;
    }

    function createEscrow(bytes32 salt, ISingleReleaseEscrow.Escrow calldata escrowProperties)
        external
        returns (address escrow)
    {
        // Salt is bound to the caller so nobody can squat a predicted address.
        escrow = Clones.cloneDeterministic(implementation, _saltFor(msg.sender, salt));
        ISingleReleaseEscrow(escrow).initialize(escrowProperties);
        emit EscrowCreated(escrow, msg.sender, escrowProperties.engagementId, escrowProperties.roles.admin, salt);
    }

    function predictEscrowAddress(address creator, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _saltFor(creator, salt));
    }

    function getMultipleEscrowBalances(address[] calldata escrows) external view returns (AddressBalance[] memory) {
        if (escrows.length > MAX_ESCROWS) revert TooManyEscrowsRequested();
        AddressBalance[] memory balances = new AddressBalance[](escrows.length);
        for (uint256 i; i < escrows.length; ++i) {
            IERC20Metadata token = IERC20Metadata(ISingleReleaseEscrow(escrows[i]).token());
            balances[i] = AddressBalance({
                escrow: escrows[i], balance: token.balanceOf(escrows[i]), tokenDecimals: token.decimals()
            });
        }
        return balances;
    }

    function _saltFor(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
