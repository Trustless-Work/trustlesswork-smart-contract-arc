// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISingleReleaseEscrow} from "./interfaces/ISingleReleaseEscrow.sol";
import {ISingleReleaseEscrowFactory} from "./interfaces/ISingleReleaseEscrowFactory.sol";

/// @title Trustless Work single-release escrow (Arc / EVM port of Soroban v2)
/// @notice One clone per escrow, deployed and initialized by
/// `SingleReleaseEscrowFactory`. Every Soroban `x.require_auth()` on a role
/// argument becomes a check on `msg.sender`, so those arguments are gone.
/// Holds an ERC-20 (on Arc: USDC's 6-decimal ERC-20 interface); native value
/// is never accepted.
contract SingleReleaseEscrow is ISingleReleaseEscrow, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

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

    address public immutable factory;

    Escrow private _escrow;
    bool private _initialized;
    /// @dev Cumulative amount ever funded; gates the post-funding property locks.
    uint256 public fundedAmount;

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    ////////////////////////
    // Escrow /////
    ////////////////////////

    function initialize(Escrow calldata p) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (_initialized) revert EscrowAlreadyInitialized();
        _validateEscrowConditions(p, true);

        _initialized = true;
        _escrow.engagementId = p.engagementId;
        _escrow.title = p.title;
        _escrow.roles = p.roles;
        _escrow.description = p.description;
        _escrow.amount = p.amount;
        _escrow.platformFee = p.platformFee;
        _escrow.token = p.token;
        _escrow.receiverMemo = p.receiverMemo;
        for (uint256 i; i < p.milestones.length; ++i) {
            _pushMilestone(p.milestones[i]);
        }

        emit EscrowInitialized(p.engagementId, p.amount, p.platformFee, p.token, p.roles.receiver);
    }

    /// @param expectedEscrowHash `escrowHash()` as seen by the funder; replaces
    /// Soroban's full `expected_escrow` equality check.
    function fundEscrow(uint256 amount, bytes32 expectedEscrowHash) external nonReentrant {
        _fund(amount, expectedEscrowHash);
    }

    /// @notice Same as `fundEscrow`, approving via EIP-2612 in the same call.
    function fundEscrowWithPermit(
        uint256 amount,
        bytes32 expectedEscrowHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        _requireInitialized();
        // A front-run permit consumes the signature but leaves the allowance
        // in place, so a failed permit is only fatal if the allowance is short.
        try IERC20Permit(_escrow.token).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _fund(amount, expectedEscrowHash);
    }

    function releaseFunds() external nonReentrant {
        _requireInitialized();
        _validateReleaseConditions(msg.sender);
        _releaseExecute();
    }

    /// @dev `milestones`, `dispute` and `released` in the argument are ignored
    /// and kept from storage, exactly like the Soroban version.
    function updateEscrow(Escrow calldata p) external {
        _requireInitialized();
        _validateEscrowConditions(p, false);

        Escrow storage e = _escrow;
        EscrowPropertyChanges memory changes = EscrowPropertyChanges({
            engagementId: !_eq(e.engagementId, p.engagementId),
            title: !_eq(e.title, p.title),
            description: !_eq(e.description, p.description),
            amount: e.amount != p.amount,
            platformFee: e.platformFee != p.platformFee,
            roles: _rolesHash(e.roles) != keccak256(abi.encode(p.roles)),
            token: e.token != p.token,
            receiverMemo: e.receiverMemo != p.receiverMemo,
            oldAmount: e.amount,
            newAmount: p.amount,
            oldPlatformFee: e.platformFee,
            newPlatformFee: p.platformFee
        });

        e.engagementId = p.engagementId;
        e.title = p.title;
        e.roles = p.roles;
        e.description = p.description;
        e.amount = p.amount;
        e.platformFee = p.platformFee;
        e.token = p.token;
        e.receiverMemo = p.receiverMemo;

        emit EscrowUpdated(p.engagementId, msg.sender, changes);
    }

    function manageMilestones(Milestone[] calldata newMilestones, MilestoneUpdate[] calldata milestoneUpdates)
        external
    {
        _requireInitialized();
        _validateManageMilestones(newMilestones, milestoneUpdates);

        MilestoneUpdatedEntry[] memory updated = new MilestoneUpdatedEntry[](milestoneUpdates.length);
        for (uint256 i; i < milestoneUpdates.length; ++i) {
            MilestoneUpdate calldata u = milestoneUpdates[i];
            bytes32 descHash;
            if (u.setDescription) {
                _escrow.milestones[u.index].description = u.newDescription;
                descHash = sha256(bytes(u.newDescription));
            }
            updated[i] = MilestoneUpdatedEntry({index: u.index, newDescriptionHash: descHash});
        }

        uint256 baseIndex = _escrow.milestones.length;
        MilestoneAddedEntry[] memory added = new MilestoneAddedEntry[](newMilestones.length);
        for (uint256 i; i < newMilestones.length; ++i) {
            _pushMilestone(newMilestones[i]);
            added[i] = MilestoneAddedEntry({
                index: uint32(baseIndex + i), descriptionHash: sha256(bytes(newMilestones[i].description))
            });
        }

        emit MilestonesManaged(
            _escrow.engagementId,
            msg.sender,
            uint32(newMilestones.length),
            uint32(milestoneUpdates.length),
            added,
            updated
        );
    }

    ////////////////////////
    // Milestones /////
    ////////////////////////

    function changeMilestoneStatus(MilestoneStatusUpdate[] calldata updates) external {
        _requireInitialized();
        _validateBatchMilestoneStatusChange(updates);

        MilestoneStatusEntry[] memory entries = new MilestoneStatusEntry[](updates.length);
        for (uint256 i; i < updates.length; ++i) {
            MilestoneStatusUpdate calldata u = updates[i];
            Milestone storage m = _escrow.milestones[u.milestoneIndex];
            bytes32 evidenceHash;
            if (u.setEvidence) {
                m.evidence = u.newEvidence;
                evidenceHash = sha256(bytes(u.newEvidence));
            }
            m.status = u.newStatus;
            entries[i] =
                MilestoneStatusEntry({index: u.milestoneIndex, status: u.newStatus, evidenceHash: evidenceHash});
        }

        emit MilestoneStatusChanged(_escrow.engagementId, msg.sender, entries);
    }

    function approveMilestones(uint32[] calldata milestoneIndices) external {
        _requireInitialized();
        _approveMilestones(milestoneIndices);
    }

    function approveAndReleaseMilestones(uint32[] calldata milestoneIndices) external nonReentrant {
        _requireInitialized();
        Roles storage roles = _escrow.roles;
        if (!_contains(roles.approvers, msg.sender) || !_contains(roles.releaseSigners, msg.sender)) {
            revert SignerMustBeApproverAndReleaseSigner();
        }
        _approveMilestones(milestoneIndices);
        _validateReleaseConditions(msg.sender);
        _releaseExecute();
    }

    ////////////////////////
    // Disputes /////
    ////////////////////////

    function disputeEscrow(string calldata reason) external {
        _requireInitialized();
        if (bytes(reason).length > MAX_LONG_STRING) revert StringTooLong();
        _validateDisputeFlagChange(msg.sender);

        _escrow.dispute.isDisputed = true;
        _escrow.dispute.reason = reason;

        emit EscrowDisputed(_escrow.engagementId, msg.sender, reason);
    }

    /// @dev Soroban took a `Map<Address, i128>`; the EVM version takes parallel
    /// arrays and rejects duplicates. Any rounding remainder goes to the last
    /// recipient with a non-zero net amount, in array order.
    function resolveDispute(address[] calldata recipients, uint256[] calldata amounts) external nonReentrant {
        _requireInitialized();
        uint256 total = _sumDistributions(recipients, amounts);
        uint256 balance = IERC20(_escrow.token).balanceOf(address(this));

        if (!_contains(_escrow.roles.disputeResolvers, msg.sender)) {
            revert OnlyDisputeResolverCanExecuteThisFunction();
        }
        if (!_escrow.dispute.isDisputed) revert EscrowNotInDispute();
        if (balance < total) revert InsufficientFundsForResolution();
        if (total != balance) revert DistributionsMustEqualEscrowBalance();
        if (total == 0) revert TotalAmountCannotBeZero();

        // Effects before interactions.
        _escrow.dispute.resolved = true;
        _escrow.dispute.isDisputed = false;

        (FeeResult memory fees, DistributionEntry[] memory net) = _distribute(recipients, amounts, total);
        emit DisputeResolved(_escrow.engagementId, msg.sender, fees.platformFee, fees.trustlessWorkFee, net);
    }

    function withdrawRemainingFunds(address[] calldata recipients, uint256[] calldata amounts) external nonReentrant {
        _requireInitialized();
        uint256 total = _sumDistributions(recipients, amounts);
        uint256 balance = IERC20(_escrow.token).balanceOf(address(this));
        Escrow storage e = _escrow;

        if (!_contains(e.roles.disputeResolvers, msg.sender)) revert OnlyDisputeResolverCanExecuteThisFunction();
        if (!e.dispute.isDisputed && !e.dispute.resolved && !e.released) revert EscrowNotInDispute();
        if (!(e.released || e.dispute.resolved)) revert EscrowNotFullyProcessed();
        if (total == 0) revert TotalAmountCannotBeZero();
        if (balance < total) revert InsufficientFundsForResolution();
        if (total != balance) revert DistributionsMustEqualEscrowBalance();

        (FeeResult memory fees, DistributionEntry[] memory net) = _distribute(recipients, amounts, total);
        emit FundsWithdrawn(e.engagementId, msg.sender, fees.platformFee, fees.trustlessWorkFee, net);
    }

    ////////////////////////
    // Views /////
    ////////////////////////

    function getEscrow() public view returns (Escrow memory) {
        _requireInitialized();
        return _escrow;
    }

    function escrowHash() public view returns (bytes32) {
        return keccak256(abi.encode(getEscrow()));
    }

    function token() external view returns (address) {
        _requireInitialized();
        return _escrow.token;
    }

    ////////////////////////
    // Internal: flows /////
    ////////////////////////

    function _fund(uint256 amount, bytes32 expectedEscrowHash) private {
        _requireInitialized();
        IERC20 tkn = IERC20(_escrow.token);
        if (amount == 0) revert AmountCannotBeZero();
        if (escrowHash() != expectedEscrowHash) revert EscrowPropertiesMismatch();
        if (tkn.balanceOf(msg.sender) < amount) revert InsufficientFundsForEscrowFunding();

        // Credit what actually arrived, in case of fee-on-transfer tokens.
        uint256 before = tkn.balanceOf(address(this));
        tkn.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = tkn.balanceOf(address(this)) - before;

        uint256 newFunded = fundedAmount + received;
        fundedAmount = newFunded;
        emit EscrowFunded(_escrow.engagementId, msg.sender, received, newFunded);
    }

    function _releaseExecute() private {
        Escrow storage e = _escrow;
        e.released = true;

        IERC20 tkn = IERC20(e.token);
        uint256 amount = e.amount;
        if (tkn.balanceOf(address(this)) < amount) revert EscrowBalanceNotEnoughToSendEarnings();

        FeeResult memory fees = _calculateStandardFees(amount, e.platformFee);
        if (fees.trustlessWorkFee > 0) tkn.safeTransfer(_trustlessWorkFeeRecipient(), fees.trustlessWorkFee);
        if (fees.platformFee > 0) tkn.safeTransfer(e.roles.platform, fees.platformFee);
        if (fees.receiverAmount > 0) tkn.safeTransfer(e.roles.receiver, fees.receiverAmount);

        emit FundsReleased(
            e.engagementId,
            msg.sender,
            e.roles.receiver,
            amount,
            fees.platformFee,
            fees.trustlessWorkFee,
            fees.receiverAmount
        );
    }

    function _approveMilestones(uint32[] calldata indices) private {
        _validateBatchMilestoneApprove(indices);
        for (uint256 i; i < indices.length; ++i) {
            MilestoneApprovals storage a = _escrow.milestones[indices[i]].approvals;
            a.approvedBy.push(msg.sender);
            a.approvalCount = uint32(a.approvedBy.length);
        }
        emit MilestonesApproved(_escrow.engagementId, msg.sender, indices);
    }

    function _sumDistributions(address[] calldata recipients, uint256[] calldata amounts)
        private
        pure
        returns (uint256 total)
    {
        if (recipients.length != amounts.length) revert DistributionLengthMismatch();
        if (recipients.length > MAX_DISTRIBUTIONS) revert TooManyDistributions();
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert AmountsToBeTransferredShouldBePositive();
            for (uint256 j = i + 1; j < recipients.length; ++j) {
                if (recipients[i] == recipients[j]) revert DuplicateDistributionRecipient();
            }
            total += amounts[i];
        }
    }

    /// @dev Port of `calculate_and_distribute_fees`: fees are computed once on
    /// the total, the net is split pro rata, and the truncation remainder goes
    /// to the last paid recipient so the escrow ends with a zero balance.
    function _distribute(address[] calldata recipients, uint256[] calldata amounts, uint256 total)
        private
        returns (FeeResult memory fees, DistributionEntry[] memory net)
    {
        Escrow storage e = _escrow;
        fees = _calculateStandardFees(total, e.platformFee);
        uint256 totalFees = fees.trustlessWorkFee + fees.platformFee;
        uint256 distributable = total - totalFees;

        net = new DistributionEntry[](recipients.length);
        uint256 count;
        uint256 totalNet;
        for (uint256 i; i < recipients.length; ++i) {
            uint256 netAmount = Math.mulDiv(amounts[i], distributable, total);
            if (netAmount > 0) {
                net[count++] = DistributionEntry({recipient: recipients[i], amount: netAmount});
                totalNet += netAmount;
            }
        }
        assembly ("memory-safe") {
            mstore(net, count)
        }
        if (count > 0) {
            uint256 remainder = total - totalFees - totalNet;
            if (remainder > 0) net[count - 1].amount += remainder;
        }

        IERC20 tkn = IERC20(e.token);
        if (fees.trustlessWorkFee > 0) tkn.safeTransfer(_trustlessWorkFeeRecipient(), fees.trustlessWorkFee);
        if (fees.platformFee > 0) tkn.safeTransfer(e.roles.platform, fees.platformFee);
        for (uint256 i; i < count; ++i) {
            tkn.safeTransfer(net[i].recipient, net[i].amount);
        }
    }

    function _calculateStandardFees(uint256 total, uint32 platformFeeBps) private pure returns (FeeResult memory r) {
        r.trustlessWorkFee = Math.mulDiv(total, TRUSTLESS_WORK_FEE_BPS, BASIS_POINTS_DENOMINATOR);
        r.platformFee = Math.mulDiv(total, platformFeeBps, BASIS_POINTS_DENOMINATOR);
        r.receiverAmount = total - r.trustlessWorkFee - r.platformFee;
    }

    function _pushMilestone(Milestone calldata m) private {
        Milestone storage s = _escrow.milestones.push();
        s.description = m.description;
        s.status = m.status;
        s.evidence = m.evidence;
        s.approvals.target = m.approvals.target;
        s.approvals.approvalCount = m.approvals.approvalCount;
        s.approvals.approvedBy = m.approvals.approvedBy;
    }

    function _trustlessWorkFeeRecipient() private view returns (address) {
        return ISingleReleaseEscrowFactory(factory).trustlessWorkFeeRecipient();
    }

    ////////////////////////
    // Internal: validators /////
    ////////////////////////

    function _requireInitialized() private view {
        if (!_initialized) revert EscrowNotFound();
    }

    function _validateEscrowConditions(Escrow calldata p, bool isInit) private view {
        _validateEscrowStringLengths(p);
        if (p.platformFee > MAX_PLATFORM_FEE_BPS) revert PlatformFeeTooHigh();
        if (uint256(p.platformFee) + TRUSTLESS_WORK_FEE_BPS > BASIS_POINTS_DENOMINATOR) revert PlatformFeeTooHigh();
        Roles calldata roles = p.roles;
        if (roles.approvers.length == 0) revert ApproversListEmpty();
        if (roles.serviceProviders.length == 0) revert ServiceProvidersListEmpty();
        if (roles.releaseSigners.length == 0) revert ReleaseSignersListEmpty();
        if (roles.disputeResolvers.length == 0) revert DisputeResolversListEmpty();
        if (p.amount == 0) revert AmountCannotBeZero();
        _validateNoZeroAddresses(p);

        _validateRoleLimits(roles);
        _validateDisputeResolverRoleOverlap(roles);

        if (isInit) {
            if (p.milestones.length > MAX_MILESTONES) revert TooManyMilestones();
            if (p.released || p.dispute.isDisputed || p.dispute.resolved) revert FlagsMustBeFalse();
            for (uint256 i; i < p.milestones.length; ++i) {
                MilestoneApprovals calldata a = p.milestones[i].approvals;
                if (a.approvalCount > 0 || a.approvedBy.length > 0) revert FlagsMustBeFalse();
            }
            for (uint256 i; i < p.milestones.length; ++i) {
                if (p.milestones[i].approvals.target == 0) revert TargetCannotBeZero();
            }
            for (uint256 i; i < p.milestones.length; ++i) {
                if (p.milestones[i].approvals.target > roles.approvers.length) revert TargetExceedsApprovers();
            }
        } else {
            Escrow storage existing = _escrow;
            if (msg.sender != existing.roles.admin) revert OnlyAdminAddressExecuteThisFunction();
            if (existing.roles.admin != roles.admin) revert AdminAddressCannotBeChanged();
            if (existing.roles.platform != roles.platform) revert PlatformAddressCannotBeChanged();
            if (existing.dispute.isDisputed) revert EscrowOpenedForDisputeResolution();
            if (p.released || p.dispute.isDisputed || p.dispute.resolved) revert FlagsMustBeFalse();

            if (fundedAmount > 0) {
                if (
                    !_eq(existing.engagementId, p.engagementId) || !_eq(existing.title, p.title)
                        || !_eq(existing.description, p.description)
                        || _rolesHash(existing.roles) != keccak256(abi.encode(roles)) || existing.amount != p.amount
                        || existing.platformFee != p.platformFee || existing.token != p.token
                        || existing.receiverMemo != p.receiverMemo
                ) revert EscrowPropertiesMismatch();
            }
        }
        _validateAdminRoleOverlap(roles);
    }

    function _validateEscrowStringLengths(Escrow calldata p) private pure {
        if (
            bytes(p.engagementId).length > MAX_SHORT_STRING || bytes(p.title).length > MAX_SHORT_STRING
                || bytes(p.description).length > MAX_LONG_STRING
        ) revert StringTooLong();
        for (uint256 i; i < p.milestones.length; ++i) {
            _validateMilestoneStringLengths(p.milestones[i]);
        }
    }

    function _validateMilestoneStringLengths(Milestone calldata m) private pure {
        if (
            bytes(m.description).length > MAX_LONG_STRING || bytes(m.status).length > MAX_STATUS_LEN
                || bytes(m.evidence).length > MAX_LONG_STRING
        ) revert StringTooLong();
    }

    /// @dev EVM-only: Soroban addresses cannot be "zero", EVM ones can.
    function _validateNoZeroAddresses(Escrow calldata p) private pure {
        Roles calldata r = p.roles;
        if (p.token == address(0) || r.platform == address(0) || r.receiver == address(0) || r.admin == address(0)) {
            revert ZeroAddress();
        }
        if (
            _hasZero(r.approvers) || _hasZero(r.serviceProviders) || _hasZero(r.releaseSigners)
                || _hasZero(r.disputeResolvers) || _hasZero(r.observers)
        ) revert ZeroAddress();
    }

    function _validateRoleLimits(Roles calldata r) private pure {
        if (
            r.approvers.length > MAX_ROLE_MEMBERS || r.serviceProviders.length > MAX_ROLE_MEMBERS
                || r.releaseSigners.length > MAX_ROLE_MEMBERS || r.disputeResolvers.length > MAX_ROLE_MEMBERS
                || r.observers.length > MAX_ROLE_MEMBERS
        ) revert RoleLimitExceeded();
        if (
            _hasDuplicates(r.approvers) || _hasDuplicates(r.serviceProviders) || _hasDuplicates(r.releaseSigners)
                || _hasDuplicates(r.disputeResolvers) || _hasDuplicates(r.observers)
        ) revert DuplicateAddressInRole();
    }

    function _validateDisputeResolverRoleOverlap(Roles calldata r) private pure {
        for (uint256 i; i < r.disputeResolvers.length; ++i) {
            address resolver = r.disputeResolvers[i];
            if (
                _containsCd(r.approvers, resolver) || _containsCd(r.serviceProviders, resolver)
                    || _containsCd(r.releaseSigners, resolver) || resolver == r.receiver || resolver == r.platform
            ) revert DisputeResolverOverlapsWithOtherRole();
        }
    }

    function _validateAdminRoleOverlap(Roles calldata r) private pure {
        if (
            _containsCd(r.approvers, r.admin) || _containsCd(r.serviceProviders, r.admin)
                || _containsCd(r.releaseSigners, r.admin) || _containsCd(r.disputeResolvers, r.admin)
                || r.admin == r.receiver
        ) revert AdminAddressOverlapsWithOtherRole();
    }

    function _validateReleaseConditions(address releaseSigner) private view {
        Escrow storage e = _escrow;
        if (e.released) revert EscrowAlreadyReleased();
        if (e.dispute.resolved) revert EscrowAlreadyResolved();
        if (!_contains(e.roles.releaseSigners, releaseSigner)) revert OnlyReleaseSignerCanReleaseEarnings();
        uint256 n = e.milestones.length;
        if (n == 0) revert NoMilestoneDefined();
        for (uint256 i; i < n; ++i) {
            MilestoneApprovals storage a = e.milestones[i].approvals;
            if (!(a.target > 0 && a.approvalCount >= a.target)) revert EscrowNotCompleted();
        }
        if (e.dispute.isDisputed) revert EscrowOpenedForDisputeResolution();
    }

    function _validateManageMilestones(Milestone[] calldata newMilestones, MilestoneUpdate[] calldata updates)
        private
        view
    {
        Escrow storage e = _escrow;
        if (newMilestones.length == 0 && updates.length == 0) revert NoMilestoneDefined();
        if (msg.sender != e.roles.admin) revert OnlyAdminAddressExecuteThisFunction();
        if (e.dispute.isDisputed) revert EscrowOpenedForDisputeResolution();
        if (e.released) revert EscrowAlreadyReleased();
        if (e.dispute.resolved) revert EscrowAlreadyResolved();
        if (newMilestones.length > 0) {
            if (e.milestones.length + newMilestones.length > MAX_MILESTONES) revert TooManyMilestones();
            for (uint256 i; i < newMilestones.length; ++i) {
                Milestone calldata m = newMilestones[i];
                _validateMilestoneStringLengths(m);
                if (m.approvals.target == 0) revert TargetCannotBeZero();
                if (m.approvals.approvalCount > 0 || m.approvals.approvedBy.length > 0) revert FlagsMustBeFalse();
                if (m.approvals.target > e.roles.approvers.length) revert TargetExceedsApprovers();
            }
        }
        if (updates.length > 0) {
            if (fundedAmount > 0) revert MilestoneUpdateNotAllowedWithFunds();
            for (uint256 i; i < updates.length; ++i) {
                if (updates[i].index >= e.milestones.length) revert InvalidMilestoneIndex();
                if (updates[i].setDescription && bytes(updates[i].newDescription).length > MAX_LONG_STRING) {
                    revert StringTooLong();
                }
            }
        }
    }

    function _validateBatchMilestoneStatusChange(MilestoneStatusUpdate[] calldata updates) private view {
        Escrow storage e = _escrow;
        if (updates.length == 0) revert BatchMilestoneUpdateEmpty();
        if (updates.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (!_contains(e.roles.serviceProviders, msg.sender)) revert OnlyServiceProviderCanChangeMilestoneStatus();
        // Status/evidence stay editable while a dispute is open (new evidence can
        // help resolve it), but freeze once the escrow is released or resolved.
        if (e.released) revert EscrowAlreadyReleased();
        if (e.dispute.resolved) revert EscrowAlreadyResolved();
        if (e.milestones.length == 0) revert NoMilestoneDefined();
        for (uint256 i; i < updates.length; ++i) {
            MilestoneStatusUpdate calldata u = updates[i];
            if (bytes(u.newStatus).length == 0) revert EmptyMilestoneStatus();
            if (bytes(u.newStatus).length > MAX_STATUS_LEN) revert StringTooLong();
            if (u.setEvidence && bytes(u.newEvidence).length > MAX_LONG_STRING) revert StringTooLong();
            if (u.milestoneIndex >= e.milestones.length) revert MilestoneToUpdateDoesNotExist();
        }
    }

    function _validateBatchMilestoneApprove(uint32[] calldata indices) private view {
        Escrow storage e = _escrow;
        if (indices.length == 0) revert BatchMilestoneApproveEmpty();
        if (indices.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (!_contains(e.roles.approvers, msg.sender)) revert UnauthorizedApprover();
        if (e.milestones.length == 0) revert NoMilestoneDefined();
        for (uint256 i; i < indices.length; ++i) {
            for (uint256 j = i + 1; j < indices.length; ++j) {
                if (indices[i] == indices[j]) revert DuplicateMilestoneIndex();
            }
        }
        for (uint256 i; i < indices.length; ++i) {
            if (indices[i] >= e.milestones.length) revert MilestoneToApproveDoesNotExist();
            MilestoneApprovals storage a = e.milestones[indices[i]].approvals;
            if (a.target > 0 && a.approvalCount >= a.target) revert MilestoneHasAlreadyBeenApproved();
            if (_contains(a.approvedBy, msg.sender)) revert ApproverAlreadyApprovedMilestone();
        }
    }

    function _validateDisputeFlagChange(address signer) private view {
        Escrow storage e = _escrow;
        if (e.released) revert EscrowAlreadyReleased();
        if (e.dispute.isDisputed) revert EscrowAlreadyInDispute();
        if (e.dispute.resolved) revert EscrowAlreadyResolved();
        Roles storage r = e.roles;
        if (_contains(r.disputeResolvers, signer)) revert DisputeResolverCannotDisputeTheEscrow();
        bool authorized = _contains(r.approvers, signer) || _contains(r.serviceProviders, signer)
            || signer == r.platform || _contains(r.releaseSigners, signer) || signer == r.receiver;
        if (!authorized) revert UnauthorizedToChangeDisputeFlag();
    }

    ////////////////////////
    // Internal: helpers /////
    ////////////////////////

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

    function _hasDuplicates(address[] calldata list) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            for (uint256 j = i + 1; j < list.length; ++j) {
                if (list[i] == list[j]) return true;
            }
        }
        return false;
    }

    function _hasZero(address[] calldata list) private pure returns (bool) {
        return _containsCd(list, address(0));
    }

    function _eq(string storage a, string calldata b) private view returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _rolesHash(Roles storage r) private view returns (bytes32) {
        Roles memory m = r;
        return keccak256(abi.encode(m));
    }
}
