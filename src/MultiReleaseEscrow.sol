// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMultiReleaseEscrow} from "./interfaces/IMultiReleaseEscrow.sol";
import {IMultiReleaseEscrowFactory} from "./interfaces/IMultiReleaseEscrowFactory.sol";
import {MultiReleaseValidation as V} from "./libraries/MultiReleaseValidation.sol";

/// @title Trustless Work multi-release escrow (Arc / EVM port of Soroban v2)
/// @notice One clone per escrow, deployed and initialized by
/// `MultiReleaseEscrowFactory`. Each milestone carries its own amount,
/// receiver, dispute and release flag, and is released or disputed on its own.
/// Every Soroban `x.require_auth()` on a role argument becomes a check on
/// `msg.sender`, so those arguments are gone. Holds an ERC-20 (on Arc: USDC's
/// 6-decimal ERC-20 interface); native value is never accepted. The
/// validation rules live in the linked `MultiReleaseValidation` library.
contract MultiReleaseEscrow is IMultiReleaseEscrow, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 private constant TRUSTLESS_WORK_FEE_BPS = 30;
    uint256 private constant BASIS_POINTS_DENOMINATOR = 10_000;

    address public immutable factory;

    Escrow private _escrow;
    bool private _initialized;
    /// @dev Cumulative amount ever funded; gates the post-funding locks.
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
        V.validateInitialize(p);

        _initialized = true;
        _escrow.engagementId = p.engagementId;
        _escrow.title = p.title;
        _escrow.roles = p.roles;
        _escrow.description = p.description;
        _escrow.platformFee = p.platformFee;
        _escrow.token = p.token;
        _escrow.receiverMemo = p.receiverMemo;
        uint256 total;
        for (uint256 i; i < p.milestones.length; ++i) {
            _pushMilestone(p.milestones[i]);
            total += p.milestones[i].amount;
        }

        emit EscrowInitialized(p.engagementId, uint32(p.milestones.length), total);
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

    /// @notice Releases the listed milestones, each to its own receiver.
    function releaseFunds(uint32[] calldata milestoneIndices) external nonReentrant {
        _requireInitialized();
        V.validateRelease(_escrow, msg.sender, milestoneIndices);
        _releaseExecute(milestoneIndices);
    }

    /// @dev `milestones` in the argument are ignored and kept from storage,
    /// like the Soroban version.
    function updateEscrow(Escrow calldata p) external {
        _requireInitialized();
        Escrow storage e = _escrow;
        EscrowPropertyChanges memory changes = V.validateUpdate(e, p, msg.sender, fundedAmount);

        e.engagementId = p.engagementId;
        e.title = p.title;
        e.roles = p.roles;
        e.description = p.description;
        e.platformFee = p.platformFee;
        e.token = p.token;
        e.receiverMemo = p.receiverMemo;

        emit EscrowUpdated(p.engagementId, msg.sender, changes);
    }

    function manageMilestones(Milestone[] calldata newMilestones, MilestoneUpdate[] calldata milestoneUpdates)
        external
    {
        _requireInitialized();
        V.validateManageMilestones(_escrow, newMilestones, milestoneUpdates, msg.sender, fundedAmount);

        MilestoneUpdatedEntry[] memory updated = new MilestoneUpdatedEntry[](milestoneUpdates.length);
        for (uint256 i; i < milestoneUpdates.length; ++i) {
            MilestoneUpdate calldata u = milestoneUpdates[i];
            Milestone storage m = _escrow.milestones[u.index];
            bytes32 descHash;
            if (u.setDescription) {
                m.description = u.newDescription;
                descHash = sha256(bytes(u.newDescription));
            }
            if (u.setAmount) m.amount = u.newAmount;
            updated[i] = MilestoneUpdatedEntry({
                index: u.index, amountChanged: u.setAmount, newAmount: u.newAmount, newDescriptionHash: descHash
            });
        }

        uint256 baseIndex = _escrow.milestones.length;
        MilestoneAddedEntry[] memory added = new MilestoneAddedEntry[](newMilestones.length);
        for (uint256 i; i < newMilestones.length; ++i) {
            _pushMilestone(newMilestones[i]);
            added[i] = MilestoneAddedEntry({
                index: uint32(baseIndex + i),
                amount: newMilestones[i].amount,
                descriptionHash: sha256(bytes(newMilestones[i].description))
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
        V.validateStatusChange(_escrow, updates, msg.sender);

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

    /// @notice Approves the listed milestones and releases those same ones.
    function approveAndReleaseMilestones(uint32[] calldata milestoneIndices) external nonReentrant {
        _requireInitialized();
        V.validateApproverAndReleaseSigner(_escrow, msg.sender);
        _approveMilestones(milestoneIndices);
        V.validateRelease(_escrow, msg.sender, milestoneIndices);
        _releaseExecute(milestoneIndices);
    }

    ////////////////////////
    // Disputes /////
    ////////////////////////

    function disputeMilestones(uint32[] calldata milestoneIndices, string calldata reason) external {
        _requireInitialized();
        if (bytes(reason).length > 500) revert StringTooLong();
        V.validateDispute(_escrow, msg.sender, milestoneIndices);

        for (uint256 i; i < milestoneIndices.length; ++i) {
            Dispute storage d = _escrow.milestones[milestoneIndices[i]].dispute;
            d.isDisputed = true;
            d.reason = reason;
        }

        emit MilestonesDisputed(_escrow.engagementId, msg.sender, reason, milestoneIndices);
    }

    /// @notice Settles the listed disputed milestones. The distributions must
    /// add up to exactly the sum of those milestones' amounts.
    /// @dev Soroban took a `Map<Address, i128>`; the EVM version takes parallel
    /// arrays and rejects duplicates. The rounding remainder goes to the last
    /// recipient with a non-zero net amount, in array order.
    function resolveDispute(
        uint32[] calldata milestoneIndices,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external nonReentrant {
        _requireInitialized();
        uint256 total = V.sumDistributions(recipients, amounts);
        uint256 balance = IERC20(_escrow.token).balanceOf(address(this));
        V.validateResolution(_escrow, milestoneIndices, total, balance, msg.sender);

        // Effects before interactions: only the listed milestones are settled.
        for (uint256 i; i < milestoneIndices.length; ++i) {
            Dispute storage d = _escrow.milestones[milestoneIndices[i]].dispute;
            d.resolved = true;
            d.isDisputed = false;
        }

        (FeeResult memory fees, DistributionEntry[] memory net) = _distribute(recipients, amounts, total);
        emit DisputeResolved(
            _escrow.engagementId, msg.sender, milestoneIndices, fees.platformFee, fees.trustlessWorkFee, net
        );
    }

    /// @notice Sweeps whatever balance is left once every milestone is either
    /// released or resolved.
    function withdrawRemainingFunds(address[] calldata recipients, uint256[] calldata amounts) external nonReentrant {
        _requireInitialized();
        uint256 total = V.sumDistributions(recipients, amounts);
        uint256 balance = IERC20(_escrow.token).balanceOf(address(this));
        Escrow storage e = _escrow;
        V.validateWithdraw(e, total, balance, msg.sender);

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

    function _releaseExecute(uint32[] calldata indices) private {
        Escrow storage e = _escrow;
        IERC20 tkn = IERC20(e.token);

        uint256 total;
        for (uint256 i; i < indices.length; ++i) {
            total += e.milestones[indices[i]].amount;
        }
        if (tkn.balanceOf(address(this)) < total) revert EscrowBalanceNotEnoughToSendEarnings();

        // Effects before interactions.
        for (uint256 i; i < indices.length; ++i) {
            e.milestones[indices[i]].released = true;
        }

        address feeRecipient = _trustlessWorkFeeRecipient();
        address platform = e.roles.platform;
        uint32 platformFeeBps = e.platformFee;
        MilestonePayout[] memory payouts = new MilestonePayout[](indices.length);
        for (uint256 i; i < indices.length; ++i) {
            Milestone storage m = e.milestones[indices[i]];
            FeeResult memory fees = _calculateStandardFees(m.amount, platformFeeBps);
            address receiver = m.receiver;
            if (fees.trustlessWorkFee > 0) tkn.safeTransfer(feeRecipient, fees.trustlessWorkFee);
            if (fees.platformFee > 0) tkn.safeTransfer(platform, fees.platformFee);
            if (fees.receiverAmount > 0) tkn.safeTransfer(receiver, fees.receiverAmount);
            payouts[i] = MilestonePayout({
                index: indices[i],
                receiver: receiver,
                amount: m.amount,
                platformFee: fees.platformFee,
                trustlessWorkFee: fees.trustlessWorkFee,
                netAmount: fees.receiverAmount
            });
        }

        emit FundsReleased(e.engagementId, msg.sender, payouts);
    }

    function _approveMilestones(uint32[] calldata indices) private {
        V.validateApprove(_escrow, indices, msg.sender);
        for (uint256 i; i < indices.length; ++i) {
            MilestoneApprovals storage a = _escrow.milestones[indices[i]].approvals;
            a.approvedBy.push(msg.sender);
            a.approvalCount = uint32(a.approvedBy.length);
        }
        emit MilestonesApproved(_escrow.engagementId, msg.sender, indices);
    }

    /// @dev Port of `calculate_and_distribute_fees`: fees are computed once on
    /// the total, the net is split pro rata, and the truncation remainder goes
    /// to the last paid recipient so nothing is stranded.
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
            uint256 remainder = distributable - totalNet;
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
        s.amount = m.amount;
        s.dispute = m.dispute;
        s.released = m.released;
        s.receiver = m.receiver;
    }

    function _trustlessWorkFeeRecipient() private view returns (address) {
        return IMultiReleaseEscrowFactory(factory).trustlessWorkFeeRecipient();
    }

    ////////////////////////
    // Internal: helpers /////
    ////////////////////////

    function _requireInitialized() private view {
        if (!_initialized) revert EscrowNotFound();
    }
}
