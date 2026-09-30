// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMultiReleaseEscrow as I} from "../interfaces/IMultiReleaseEscrow.sol";

/// @title Validation rules of the multi-release escrow
/// @notice Port of `contracts/escrow/src/core/validators` (Soroban v2), check
/// for check and in the same order, so each input fails with the same error.
/// @dev Deployed once and linked into `MultiReleaseEscrow`, which calls it
/// with DELEGATECALL (external library functions). Moving the rules here keeps
/// the escrow under the 24 KB contract size limit (EIP-170). Reverts use the
/// errors declared in `IMultiReleaseEscrow`, so callers decode them with the
/// escrow ABI.
library MultiReleaseValidation {
    uint256 private constant MAX_SHORT_STRING = 100;
    uint256 private constant MAX_LONG_STRING = 500;
    uint256 private constant MAX_STATUS_LEN = 50;
    uint256 private constant MAX_MILESTONES = 50;
    uint256 private constant MAX_BATCH_SIZE = 50;
    uint256 private constant MAX_DISTRIBUTIONS = 50;
    uint256 private constant MAX_ROLE_MEMBERS = 5;
    uint32 private constant MAX_PLATFORM_FEE_BPS = 99 * 100;
    uint256 private constant TRUSTLESS_WORK_FEE_BPS = 30;
    uint256 private constant BASIS_POINTS_DENOMINATOR = 10_000;

    ////////////////////////
    // Escrow /////
    ////////////////////////

    function validateInitialize(I.Escrow calldata p) external pure {
        for (uint256 i; i < p.milestones.length; ++i) {
            _validateMilestoneStringLengths(p.milestones[i]);
        }
        address[] memory receivers = new address[](p.milestones.length);
        for (uint256 i; i < p.milestones.length; ++i) {
            receivers[i] = p.milestones[i].receiver;
        }
        _validateCommon(p, receivers);
        if (_containsMem(receivers, address(0))) revert I.ZeroAddress();

        if (p.milestones.length > MAX_MILESTONES) revert I.TooManyMilestones();
        for (uint256 i; i < p.milestones.length; ++i) {
            if (_hasRuntimeState(p.milestones[i])) revert I.FlagsMustBeFalse();
        }
        for (uint256 i; i < p.milestones.length; ++i) {
            if (p.milestones[i].amount == 0) revert I.AmountCannotBeZero();
        }
        for (uint256 i; i < p.milestones.length; ++i) {
            if (p.milestones[i].approvals.target == 0) revert I.TargetCannotBeZero();
        }
        for (uint256 i; i < p.milestones.length; ++i) {
            if (p.milestones[i].approvals.target > p.roles.approvers.length) revert I.TargetExceedsApprovers();
        }
        _validateAdminRoleOverlap(p.roles, receivers);
    }

    /// @return changes Which properties the update changes (for the event).
    /// @dev Unlike Soroban, the overlap checks run against the milestones the
    /// contract keeps (storage), not the ones in the argument, which update
    /// ignores: otherwise a caller could pass look-alike milestones to slip a
    /// resolver or admin that is also a real receiver past the checks.
    function validateUpdate(I.Escrow storage existing, I.Escrow calldata p, address caller, uint256 fundedAmount)
        external
        view
        returns (I.EscrowPropertyChanges memory changes)
    {
        uint256 n = existing.milestones.length;
        address[] memory receivers = new address[](n);
        for (uint256 i; i < n; ++i) {
            receivers[i] = existing.milestones[i].receiver;
        }
        _validateCommon(p, receivers);

        if (caller != existing.roles.admin) revert I.OnlyAdminAddressExecuteThisFunction();
        if (existing.roles.admin != p.roles.admin) revert I.AdminAddressCannotBeChanged();
        if (existing.roles.platform != p.roles.platform) revert I.PlatformAddressCannotBeChanged();
        for (uint256 i; i < n; ++i) {
            if (existing.milestones[i].dispute.isDisputed) revert I.EscrowOpenedForDisputeResolution();
        }

        I.Roles memory currentRoles = existing.roles;
        changes = I.EscrowPropertyChanges({
            engagementId: keccak256(bytes(existing.engagementId)) != keccak256(bytes(p.engagementId)),
            title: keccak256(bytes(existing.title)) != keccak256(bytes(p.title)),
            description: keccak256(bytes(existing.description)) != keccak256(bytes(p.description)),
            platformFee: existing.platformFee != p.platformFee,
            roles: keccak256(abi.encode(currentRoles)) != keccak256(abi.encode(p.roles)),
            token: existing.token != p.token,
            receiverMemo: existing.receiverMemo != p.receiverMemo,
            oldPlatformFee: existing.platformFee,
            newPlatformFee: p.platformFee
        });
        if (
            fundedAmount > 0
                && (changes.engagementId
                    || changes.title
                    || changes.description
                    || changes.roles
                    || changes.platformFee
                    || changes.token
                    || changes.receiverMemo)
        ) revert I.EscrowPropertiesMismatch();

        _validateAdminRoleOverlap(p.roles, receivers);
    }

    function validateManageMilestones(
        I.Escrow storage e,
        I.Milestone[] calldata newMilestones,
        I.MilestoneUpdate[] calldata updates,
        address caller,
        uint256 fundedAmount
    ) external view {
        if (newMilestones.length == 0 && updates.length == 0) revert I.NoMilestoneDefined();
        if (caller != e.roles.admin) revert I.OnlyAdminAddressExecuteThisFunction();
        uint256 n = e.milestones.length;
        bool allReleased = n > 0;
        for (uint256 i; i < n; ++i) {
            if (e.milestones[i].dispute.isDisputed) revert I.EscrowOpenedForDisputeResolution();
            if (!e.milestones[i].released) allReleased = false;
        }
        if (allReleased) revert I.EscrowAlreadyReleased();
        for (uint256 i; i < n; ++i) {
            if (e.milestones[i].dispute.resolved) revert I.EscrowAlreadyResolved();
        }
        if (newMilestones.length > 0) {
            if (n + newMilestones.length > MAX_MILESTONES) revert I.TooManyMilestones();
            for (uint256 i; i < newMilestones.length; ++i) {
                I.Milestone calldata m = newMilestones[i];
                _validateMilestoneStringLengths(m);
                if (m.amount == 0) revert I.AmountCannotBeZero();
                if (m.approvals.target == 0) revert I.TargetCannotBeZero();
                // Soroban does not check the dispute flags here; a milestone
                // must never be born disputed or resolved.
                if (_hasRuntimeState(m)) revert I.FlagsMustBeFalse();
                if (m.approvals.target > e.roles.approvers.length) revert I.TargetExceedsApprovers();
                if (_contains(e.roles.disputeResolvers, m.receiver)) revert I.DisputeResolverOverlapsWithOtherRole();
                if (m.receiver == e.roles.admin) revert I.AdminAddressOverlapsWithOtherRole();
                if (m.receiver == address(0)) revert I.ZeroAddress();
            }
        }
        if (updates.length > 0) {
            if (fundedAmount > 0) revert I.MilestoneUpdateNotAllowedWithFunds();
            for (uint256 i; i < updates.length; ++i) {
                I.MilestoneUpdate calldata u = updates[i];
                if (u.index >= n) revert I.InvalidMilestoneIndex();
                if (u.setDescription && bytes(u.newDescription).length > MAX_LONG_STRING) revert I.StringTooLong();
                if (u.setAmount && u.newAmount == 0) revert I.AmountCannotBeZero();
            }
        }
    }

    ////////////////////////
    // Release /////
    ////////////////////////

    function validateRelease(I.Escrow storage e, address releaseSigner, uint32[] calldata indices) external view {
        if (!_contains(e.roles.releaseSigners, releaseSigner)) revert I.OnlyReleaseSignerCanReleaseEarnings();
        if (indices.length == 0) revert I.ReleaseMilestonesEmpty();
        uint256 n = e.milestones.length;
        // Bound the input before the quadratic duplicate scan.
        if (indices.length > n) revert I.BatchTooLarge();
        if (_hasDuplicateIndexes(indices)) revert I.DuplicateMilestoneIndex();
        for (uint256 i; i < indices.length; ++i) {
            if (indices[i] >= n) revert I.InvalidMilestoneIndex();
            I.Milestone storage m = e.milestones[indices[i]];
            if (m.dispute.isDisputed) revert I.EscrowOpenedForDisputeResolution();
            if (m.dispute.resolved) revert I.EscrowAlreadyResolved();
            if (!(m.approvals.target > 0 && m.approvals.approvalCount >= m.approvals.target)) {
                revert I.EscrowNotCompleted();
            }
            if (m.released) revert I.MilestoneAlreadyReleased();
        }
    }

    function validateApproverAndReleaseSigner(I.Escrow storage e, address signer) external view {
        if (!_contains(e.roles.approvers, signer) || !_contains(e.roles.releaseSigners, signer)) {
            revert I.SignerMustBeApproverAndReleaseSigner();
        }
    }

    ////////////////////////
    // Milestones /////
    ////////////////////////

    function validateStatusChange(I.Escrow storage e, I.MilestoneStatusUpdate[] calldata updates, address caller)
        external
        view
    {
        if (updates.length == 0) revert I.BatchMilestoneUpdateEmpty();
        if (updates.length > MAX_BATCH_SIZE) revert I.BatchTooLarge();
        if (!_contains(e.roles.serviceProviders, caller)) revert I.OnlyServiceProviderCanChangeMilestoneStatus();
        uint256 n = e.milestones.length;
        if (n == 0) revert I.NoMilestoneDefined();
        for (uint256 i; i < updates.length; ++i) {
            I.MilestoneStatusUpdate calldata u = updates[i];
            if (bytes(u.newStatus).length == 0) revert I.EmptyMilestoneStatus();
            if (bytes(u.newStatus).length > MAX_STATUS_LEN) revert I.StringTooLong();
            if (u.setEvidence && bytes(u.newEvidence).length > MAX_LONG_STRING) revert I.StringTooLong();
            if (u.milestoneIndex >= n) revert I.MilestoneToUpdateDoesNotExist();
            // Status/evidence stay editable while a milestone's dispute is open
            // (fresh evidence can help resolve it), but freeze once the
            // milestone is released or its dispute resolved.
            I.Milestone storage m = e.milestones[u.milestoneIndex];
            if (m.released) revert I.MilestoneAlreadyReleased();
            if (m.dispute.resolved) revert I.MilestoneAlreadyResolved();
        }
    }

    function validateApprove(I.Escrow storage e, uint32[] calldata indices, address caller) external view {
        if (indices.length == 0) revert I.BatchMilestoneApproveEmpty();
        if (indices.length > MAX_BATCH_SIZE) revert I.BatchTooLarge();
        if (!_contains(e.roles.approvers, caller)) revert I.UnauthorizedApprover();
        if (e.milestones.length == 0) revert I.NoMilestoneDefined();
        if (_hasDuplicateIndexes(indices)) revert I.DuplicateMilestoneIndex();
        for (uint256 i; i < indices.length; ++i) {
            if (indices[i] >= e.milestones.length) revert I.MilestoneToApproveDoesNotExist();
            I.MilestoneApprovals storage a = e.milestones[indices[i]].approvals;
            if (a.target > 0 && a.approvalCount >= a.target) revert I.MilestoneHasAlreadyBeenApproved();
            if (_contains(a.approvedBy, caller)) revert I.ApproverAlreadyApprovedMilestone();
        }
    }

    ////////////////////////
    // Disputes /////
    ////////////////////////

    function validateDispute(I.Escrow storage e, address signer, uint32[] calldata indices) external view {
        uint256 n = e.milestones.length;
        if (indices.length == 0) revert I.BatchMilestoneDisputeEmpty();
        if (indices.length > n) revert I.TooManyMilestones();
        if (_hasDuplicateIndexes(indices)) revert I.InvalidMilestoneIndex();

        I.Roles storage r = e.roles;
        if (_contains(r.disputeResolvers, signer)) revert I.DisputeResolverCannotDisputeTheEscrow();
        bool globalRole = _contains(r.approvers, signer) || _contains(r.serviceProviders, signer)
            || signer == r.platform || _contains(r.releaseSigners, signer);
        if (!globalRole) {
            // A receiver may only dispute its own milestones.
            for (uint256 i; i < indices.length; ++i) {
                if (indices[i] >= n || e.milestones[indices[i]].receiver != signer) {
                    revert I.UnauthorizedToChangeDisputeFlag();
                }
            }
        }

        for (uint256 i; i < indices.length; ++i) {
            if (indices[i] >= n) revert I.InvalidMilestoneIndex();
            I.Milestone storage m = e.milestones[indices[i]];
            if (m.dispute.resolved) revert I.EscrowAlreadyResolved();
            if (m.dispute.isDisputed) revert I.MilestoneAlreadyDisputed();
            if (m.released) revert I.MilestoneAlreadyReleased();
        }
    }

    function validateResolution(
        I.Escrow storage e,
        uint32[] calldata indices,
        uint256 total,
        uint256 balance,
        address caller
    ) external view {
        if (!_contains(e.roles.disputeResolvers, caller)) {
            revert I.OnlyDisputeResolverCanExecuteThisFunction();
        }
        if (indices.length == 0) revert I.EscrowNotInDispute();
        if (_hasDuplicateIndexes(indices)) revert I.InvalidMilestoneIndex();

        uint256 milestoneTotal;
        for (uint256 i; i < indices.length; ++i) {
            if (indices[i] >= e.milestones.length) revert I.InvalidMilestoneIndex();
            I.Milestone storage m = e.milestones[indices[i]];
            if (!m.dispute.isDisputed) revert I.EscrowNotInDispute();
            if (m.dispute.resolved) revert I.EscrowAlreadyResolved();
            milestoneTotal += m.amount;
        }
        if (total != milestoneTotal) revert I.DistributionsMustEqualEscrowBalance();
        if (balance < total) revert I.InsufficientFundsForResolution();
        if (total == 0) revert I.TotalAmountCannotBeZero();
    }

    function validateWithdraw(I.Escrow storage e, uint256 total, uint256 balance, address caller) external view {
        if (!_contains(e.roles.disputeResolvers, caller)) revert I.OnlyDisputeResolverCanExecuteThisFunction();
        uint256 n = e.milestones.length;
        bool anyDisputeActivity;
        bool allReleased = n > 0;
        bool allProcessed = true;
        for (uint256 i; i < n; ++i) {
            I.Milestone storage m = e.milestones[i];
            if (m.dispute.isDisputed || m.dispute.resolved) anyDisputeActivity = true;
            if (!m.released) allReleased = false;
            if (!(m.released || m.dispute.resolved)) allProcessed = false;
        }
        if (!anyDisputeActivity && !allReleased) revert I.EscrowNotInDispute();
        if (!allProcessed) revert I.EscrowNotFullyProcessed();
        if (total == 0) revert I.TotalAmountCannotBeZero();
        if (balance < total) revert I.InsufficientFundsForResolution();
        if (total != balance) revert I.DistributionsMustEqualEscrowBalance();
    }

    /// @dev Soroban took a `Map<Address, i128>`; the EVM version takes
    /// parallel arrays, so it also rejects mismatched lengths and duplicates.
    function sumDistributions(address[] calldata recipients, uint256[] calldata amounts)
        external
        pure
        returns (uint256 total)
    {
        if (recipients.length != amounts.length) revert I.DistributionLengthMismatch();
        if (recipients.length > MAX_DISTRIBUTIONS) revert I.TooManyDistributions();
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert I.ZeroAddress();
            if (amounts[i] == 0) revert I.AmountsToBeTransferredShouldBePositive();
            for (uint256 j = i + 1; j < recipients.length; ++j) {
                if (recipients[i] == recipients[j]) revert I.DuplicateDistributionRecipient();
            }
            total += amounts[i];
        }
    }

    ////////////////////////
    // Internal /////
    ////////////////////////

    /// @dev Checks shared by initialize and update, in the Soroban order.
    /// `receivers` are the milestone receivers the roles are checked against.
    function _validateCommon(I.Escrow calldata p, address[] memory receivers) private pure {
        if (
            bytes(p.engagementId).length > MAX_SHORT_STRING || bytes(p.title).length > MAX_SHORT_STRING
                || bytes(p.description).length > MAX_LONG_STRING
        ) revert I.StringTooLong();
        if (p.platformFee > MAX_PLATFORM_FEE_BPS) revert I.PlatformFeeTooHigh();
        if (uint256(p.platformFee) + TRUSTLESS_WORK_FEE_BPS > BASIS_POINTS_DENOMINATOR) revert I.PlatformFeeTooHigh();
        I.Roles calldata r = p.roles;
        if (r.approvers.length == 0) revert I.ApproversListEmpty();
        if (r.serviceProviders.length == 0) revert I.ServiceProvidersListEmpty();
        if (r.releaseSigners.length == 0) revert I.ReleaseSignersListEmpty();
        if (r.disputeResolvers.length == 0) revert I.DisputeResolversListEmpty();
        // EVM-only: Soroban addresses cannot be "zero", EVM ones can.
        if (
            p.token == address(0) || r.platform == address(0) || r.admin == address(0)
                || _containsCd(r.approvers, address(0)) || _containsCd(r.serviceProviders, address(0))
                || _containsCd(r.releaseSigners, address(0)) || _containsCd(r.disputeResolvers, address(0))
                || _containsCd(r.observers, address(0))
        ) revert I.ZeroAddress();
        if (
            r.approvers.length > MAX_ROLE_MEMBERS || r.serviceProviders.length > MAX_ROLE_MEMBERS
                || r.releaseSigners.length > MAX_ROLE_MEMBERS || r.disputeResolvers.length > MAX_ROLE_MEMBERS
                || r.observers.length > MAX_ROLE_MEMBERS
        ) revert I.RoleLimitExceeded();
        if (
            _hasDuplicates(r.approvers) || _hasDuplicates(r.serviceProviders) || _hasDuplicates(r.releaseSigners)
                || _hasDuplicates(r.disputeResolvers) || _hasDuplicates(r.observers)
        ) revert I.DuplicateAddressInRole();
        // A milestone receiver may open a dispute, so a resolver must never be one.
        for (uint256 i; i < r.disputeResolvers.length; ++i) {
            address resolver = r.disputeResolvers[i];
            if (
                _containsCd(r.approvers, resolver) || _containsCd(r.serviceProviders, resolver)
                    || _containsCd(r.releaseSigners, resolver) || resolver == r.platform
                    || _containsMem(receivers, resolver)
            ) revert I.DisputeResolverOverlapsWithOtherRole();
        }
    }

    function _validateAdminRoleOverlap(I.Roles calldata r, address[] memory receivers) private pure {
        if (
            _containsCd(r.approvers, r.admin) || _containsCd(r.serviceProviders, r.admin)
                || _containsCd(r.releaseSigners, r.admin) || _containsCd(r.disputeResolvers, r.admin)
                || _containsMem(receivers, r.admin)
        ) revert I.AdminAddressOverlapsWithOtherRole();
    }

    function _validateMilestoneStringLengths(I.Milestone calldata m) private pure {
        if (
            bytes(m.description).length > MAX_LONG_STRING || bytes(m.status).length > MAX_STATUS_LEN
                || bytes(m.evidence).length > MAX_LONG_STRING
        ) revert I.StringTooLong();
    }

    /// @dev A new milestone must carry no approvals, release or dispute state.
    function _hasRuntimeState(I.Milestone calldata m) private pure returns (bool) {
        return m.approvals.approvalCount > 0 || m.approvals.approvedBy.length > 0 || m.released || m.dispute.isDisputed
            || m.dispute.resolved;
    }

    function _hasDuplicateIndexes(uint32[] calldata indices) private pure returns (bool) {
        for (uint256 i; i < indices.length; ++i) {
            for (uint256 j = i + 1; j < indices.length; ++j) {
                if (indices[i] == indices[j]) return true;
            }
        }
        return false;
    }

    function _hasDuplicates(address[] calldata list) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            for (uint256 j = i + 1; j < list.length; ++j) {
                if (list[i] == list[j]) return true;
            }
        }
        return false;
    }

    function _contains(address[] storage list, address a) private view returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

    function _containsCd(address[] calldata list, address a) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

    function _containsMem(address[] memory list, address a) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }
}
