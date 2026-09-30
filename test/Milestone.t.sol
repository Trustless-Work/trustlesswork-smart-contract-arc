// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./utils/Base.t.sol";
import {IMultiReleaseEscrow} from "../src/interfaces/IMultiReleaseEscrow.sol";
import {MultiReleaseEscrow} from "../src/MultiReleaseEscrow.sol";

contract MilestoneTest is BaseTest {
    function _status(uint32 index, string memory status, bool setEvidence, string memory evidence)
        internal
        pure
        returns (IMultiReleaseEscrow.MilestoneStatusUpdate[] memory u)
    {
        u = new IMultiReleaseEscrow.MilestoneStatusUpdate[](1);
        u[0] = IMultiReleaseEscrow.MilestoneStatusUpdate({
            milestoneIndex: index, newStatus: status, setEvidence: setEvidence, newEvidence: evidence
        });
    }

    function _noMilestones() internal pure returns (IMultiReleaseEscrow.Milestone[] memory) {
        return new IMultiReleaseEscrow.Milestone[](0);
    }

    function _noUpdates() internal pure returns (IMultiReleaseEscrow.MilestoneUpdate[] memory) {
        return new IMultiReleaseEscrow.MilestoneUpdate[](0);
    }

    function _newMilestone(string memory d, uint256 amount, address to)
        internal
        pure
        returns (IMultiReleaseEscrow.Milestone[] memory add)
    {
        add = new IMultiReleaseEscrow.Milestone[](1);
        add[0] = _milestone(d, amount, to);
    }

    function test_change_milestone_status_emits_evidence_hash() public {
        MultiReleaseEscrow escrow = _defaultEscrow();

        IMultiReleaseEscrow.MilestoneStatusEntry[] memory entries = new IMultiReleaseEscrow.MilestoneStatusEntry[](1);
        entries[0] =
            IMultiReleaseEscrow.MilestoneStatusEntry({index: 1, status: "Done", evidenceHash: sha256("ipfs://proof")});
        vm.expectEmit(address(escrow));
        emit IMultiReleaseEscrow.MilestoneStatusChanged("ENG-001", provider, entries);
        vm.prank(provider);
        escrow.changeMilestoneStatus(_status(1, "Done", true, "ipfs://proof"));

        entries[0] = IMultiReleaseEscrow.MilestoneStatusEntry({index: 1, status: "Reviewed", evidenceHash: bytes32(0)});
        vm.expectEmit(address(escrow));
        emit IMultiReleaseEscrow.MilestoneStatusChanged("ENG-001", provider, entries);
        vm.prank(provider);
        escrow.changeMilestoneStatus(_status(1, "Reviewed", false, ""));

        IMultiReleaseEscrow.Milestone memory m = escrow.getEscrow().milestones[1];
        assertEq(m.status, "Reviewed");
        assertEq(m.evidence, "ipfs://proof");
    }

    function test_change_milestone_status_validation() public {
        MultiReleaseEscrow escrow = _defaultEscrow();

        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.OnlyServiceProviderCanChangeMilestoneStatus.selector);
        escrow.changeMilestoneStatus(_status(0, "Done", false, ""));

        vm.startPrank(provider);
        vm.expectRevert(IMultiReleaseEscrow.BatchMilestoneUpdateEmpty.selector);
        escrow.changeMilestoneStatus(new IMultiReleaseEscrow.MilestoneStatusUpdate[](0));
        vm.expectRevert(IMultiReleaseEscrow.EmptyMilestoneStatus.selector);
        escrow.changeMilestoneStatus(_status(0, "", false, ""));
        vm.expectRevert(IMultiReleaseEscrow.MilestoneToUpdateDoesNotExist.selector);
        escrow.changeMilestoneStatus(_status(2, "Done", false, ""));
        vm.expectRevert(IMultiReleaseEscrow.StringTooLong.selector);
        escrow.changeMilestoneStatus(_status(0, string(new bytes(51)), false, ""));
        vm.stopPrank();
    }

    function test_status_change_frozen_per_milestone_once_released_or_resolved() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);

        // Milestone 0 released: frozen. Milestone 1 disputed: still editable.
        _approve(escrow, _idx(0));
        _release(escrow, _idx(0));
        _dispute(escrow, _idx(1));

        vm.startPrank(provider);
        vm.expectRevert(IMultiReleaseEscrow.MilestoneAlreadyReleased.selector);
        escrow.changeMilestoneStatus(_status(0, "After", false, ""));
        escrow.changeMilestoneStatus(_status(1, "More evidence", true, "ipfs://more"));
        vm.stopPrank();

        vm.prank(resolver);
        escrow.resolveDispute(_idx(1), _one(receiver2), _amounts(400 * USDC));
        vm.prank(provider);
        vm.expectRevert(IMultiReleaseEscrow.MilestoneAlreadyResolved.selector);
        escrow.changeMilestoneStatus(_status(1, "After", false, ""));
    }

    function test_target_requires_multiple_approvers() public {
        IMultiReleaseEscrow.Escrow memory p = _props(0);
        p.roles.approvers = _two(approver, approver2);
        p.milestones[0].approvals.target = 2;
        MultiReleaseEscrow escrow = _create(p);
        _fund(escrow, 1000 * USDC);

        _approve(escrow, _idx(0, 1));
        vm.prank(approver);
        vm.expectRevert(IMultiReleaseEscrow.ApproverAlreadyApprovedMilestone.selector);
        escrow.approveMilestones(_idx(0));

        // Milestone 1 (target 1) is releasable, milestone 0 (target 2) is not yet.
        _release(escrow, _idx(1));
        vm.prank(releaseSigner);
        vm.expectRevert(IMultiReleaseEscrow.EscrowNotCompleted.selector);
        escrow.releaseFunds(_idx(0));

        vm.prank(approver2);
        escrow.approveMilestones(_idx(0));
        vm.prank(approver2);
        vm.expectRevert(IMultiReleaseEscrow.MilestoneHasAlreadyBeenApproved.selector);
        escrow.approveMilestones(_idx(0));
        _release(escrow, _idx(0));
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_approve_milestones_validation() public {
        MultiReleaseEscrow escrow = _defaultEscrow();

        // Unauthorized fails before the duplicate check.
        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.UnauthorizedApprover.selector);
        escrow.approveMilestones(_idx(0, 0));

        vm.startPrank(approver);
        vm.expectRevert(IMultiReleaseEscrow.DuplicateMilestoneIndex.selector);
        escrow.approveMilestones(_idx(0, 0));
        vm.expectRevert(IMultiReleaseEscrow.BatchMilestoneApproveEmpty.selector);
        escrow.approveMilestones(new uint32[](0));
        // scenario_a_approve_out_of_range_index_is_atomic
        vm.expectRevert(IMultiReleaseEscrow.MilestoneToApproveDoesNotExist.selector);
        escrow.approveMilestones(_idx(0, 5));
        vm.stopPrank();
        assertEq(escrow.getEscrow().milestones[0].approvals.approvalCount, 0);
    }

    function test_manage_milestones_add_and_update() public {
        MultiReleaseEscrow escrow = _defaultEscrow();

        IMultiReleaseEscrow.MilestoneUpdate[] memory upd = new IMultiReleaseEscrow.MilestoneUpdate[](1);
        upd[0] = IMultiReleaseEscrow.MilestoneUpdate({
            index: 0, setDescription: true, newDescription: "Design v2", setAmount: true, newAmount: 650 * USDC
        });

        IMultiReleaseEscrow.MilestoneAddedEntry[] memory added = new IMultiReleaseEscrow.MilestoneAddedEntry[](1);
        added[0] = IMultiReleaseEscrow.MilestoneAddedEntry({index: 2, amount: 50 * USDC, descriptionHash: sha256("QA")});
        IMultiReleaseEscrow.MilestoneUpdatedEntry[] memory updated = new IMultiReleaseEscrow.MilestoneUpdatedEntry[](1);
        updated[0] = IMultiReleaseEscrow.MilestoneUpdatedEntry({
            index: 0, amountChanged: true, newAmount: 650 * USDC, newDescriptionHash: sha256("Design v2")
        });
        vm.expectEmit(address(escrow));
        emit IMultiReleaseEscrow.MilestonesManaged("ENG-001", admin, 1, 1, added, updated);

        vm.prank(admin);
        escrow.manageMilestones(_newMilestone("QA", 50 * USDC, receiver2), upd);

        IMultiReleaseEscrow.Escrow memory e = escrow.getEscrow();
        assertEq(e.milestones.length, 3);
        assertEq(e.milestones[0].description, "Design v2");
        assertEq(e.milestones[0].amount, 650 * USDC);
        assertEq(e.milestones[2].receiver, receiver2);
    }

    function test_manage_milestones_with_funds() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1 * USDC);
        _approve(escrow, _idx(0));

        // test_append_milestones_with_funds_and_existing_approved
        vm.prank(admin);
        escrow.manageMilestones(_newMilestone("Extra", 5 * USDC, receiver), _noUpdates());
        assertEq(escrow.getEscrow().milestones[0].approvals.approvalCount, 1);

        IMultiReleaseEscrow.MilestoneUpdate[] memory upd = new IMultiReleaseEscrow.MilestoneUpdate[](1);
        upd[0].index = 1;
        upd[0].setAmount = true;
        upd[0].newAmount = 1;
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.MilestoneUpdateNotAllowedWithFunds.selector);
        escrow.manageMilestones(_noMilestones(), upd);
    }

    function test_manage_milestones_validation() public {
        MultiReleaseEscrow escrow = _defaultEscrow();

        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.NoMilestoneDefined.selector);
        escrow.manageMilestones(_noMilestones(), _noUpdates());

        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.OnlyAdminAddressExecuteThisFunction.selector);
        escrow.manageMilestones(_newMilestone("x", 1, receiver), _noUpdates());

        vm.startPrank(admin);
        vm.expectRevert(IMultiReleaseEscrow.AmountCannotBeZero.selector);
        escrow.manageMilestones(_newMilestone("x", 0, receiver), _noUpdates());
        vm.expectRevert(IMultiReleaseEscrow.StringTooLong.selector);
        escrow.manageMilestones(_newMilestone(string(new bytes(501)), 1, receiver), _noUpdates());
        // test_manage_milestones_rejects_dispute_resolver_as_receiver
        vm.expectRevert(IMultiReleaseEscrow.DisputeResolverOverlapsWithOtherRole.selector);
        escrow.manageMilestones(_newMilestone("x", 1, resolver), _noUpdates());
        // test_manage_milestones_rejects_admin_as_receiver
        vm.expectRevert(IMultiReleaseEscrow.AdminAddressOverlapsWithOtherRole.selector);
        escrow.manageMilestones(_newMilestone("x", 1, admin), _noUpdates());
        vm.expectRevert(IMultiReleaseEscrow.ZeroAddress.selector);
        escrow.manageMilestones(_newMilestone("x", 1, address(0)), _noUpdates());

        // test_manage_milestones_rejects_non_positive_amount_update
        IMultiReleaseEscrow.MilestoneUpdate[] memory upd = new IMultiReleaseEscrow.MilestoneUpdate[](1);
        upd[0].setAmount = true;
        vm.expectRevert(IMultiReleaseEscrow.AmountCannotBeZero.selector);
        escrow.manageMilestones(_noMilestones(), upd);

        upd[0].index = 9;
        upd[0].newAmount = 1;
        vm.expectRevert(IMultiReleaseEscrow.InvalidMilestoneIndex.selector);
        escrow.manageMilestones(_noMilestones(), upd);
        vm.stopPrank();
    }

    /// Soroban lets a new milestone arrive already disputed or resolved; the
    /// port rejects it like initialize does.
    function test_manage_milestones_rejects_new_milestone_with_dispute_state() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        IMultiReleaseEscrow.Milestone[] memory add = _newMilestone("x", 1, receiver);
        add[0].dispute.isDisputed = true;
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.FlagsMustBeFalse.selector);
        escrow.manageMilestones(add, _noUpdates());

        add[0].dispute.isDisputed = false;
        add[0].dispute.resolved = true;
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.FlagsMustBeFalse.selector);
        escrow.manageMilestones(add, _noUpdates());
    }

    function test_manage_milestones_blocked_by_escrow_state() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);

        _dispute(escrow, _idx(1));
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.EscrowOpenedForDisputeResolution.selector);
        escrow.manageMilestones(_newMilestone("x", 1, receiver), _noUpdates());

        vm.prank(resolver);
        escrow.resolveDispute(_idx(1), _one(receiver2), _amounts(400 * USDC));
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.EscrowAlreadyResolved.selector);
        escrow.manageMilestones(_newMilestone("x", 1, receiver), _noUpdates());

        MultiReleaseEscrow other = _defaultEscrow();
        _fund(other, 1000 * USDC);
        _approve(other, _idx(0, 1));
        _release(other, _idx(0, 1));
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.EscrowAlreadyReleased.selector);
        other.manageMilestones(_newMilestone("x", 1, receiver), _noUpdates());
    }
}
