// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./utils/Base.t.sol";
import {ISingleReleaseEscrow} from "../src/interfaces/ISingleReleaseEscrow.sol";
import {SingleReleaseEscrow} from "../src/SingleReleaseEscrow.sol";

contract MilestoneTest is BaseTest {
    function _status(uint32 index, string memory status, bool setEvidence, string memory evidence)
        internal
        pure
        returns (ISingleReleaseEscrow.MilestoneStatusUpdate[] memory u)
    {
        u = new ISingleReleaseEscrow.MilestoneStatusUpdate[](1);
        u[0] = ISingleReleaseEscrow.MilestoneStatusUpdate({
            milestoneIndex: index, newStatus: status, setEvidence: setEvidence, newEvidence: evidence
        });
    }

    function test_change_milestone_status_emits_evidence_hash() public {
        SingleReleaseEscrow escrow = _defaultEscrow();

        ISingleReleaseEscrow.MilestoneStatusEntry[] memory entries = new ISingleReleaseEscrow.MilestoneStatusEntry[](1);
        entries[0] = ISingleReleaseEscrow.MilestoneStatusEntry({
            index: 1, status: "Done", evidenceHash: sha256(bytes("ipfs://proof"))
        });
        vm.expectEmit(address(escrow));
        emit ISingleReleaseEscrow.MilestoneStatusChanged("ENG-001", provider, entries);
        vm.prank(provider);
        escrow.changeMilestoneStatus(_status(1, "Done", true, "ipfs://proof"));

        ISingleReleaseEscrow.Milestone memory m = escrow.getEscrow().milestones[1];
        assertEq(m.status, "Done");
        assertEq(m.evidence, "ipfs://proof");

        // Untouched evidence reports a zero hash and keeps the stored value.
        entries[0] = ISingleReleaseEscrow.MilestoneStatusEntry({index: 1, status: "Reviewed", evidenceHash: bytes32(0)});
        vm.expectEmit(address(escrow));
        emit ISingleReleaseEscrow.MilestoneStatusChanged("ENG-001", provider, entries);
        vm.prank(provider);
        escrow.changeMilestoneStatus(_status(1, "Reviewed", false, ""));
        assertEq(escrow.getEscrow().milestones[1].evidence, "ipfs://proof");
    }

    function test_change_milestone_status_validation() public {
        SingleReleaseEscrow escrow = _defaultEscrow();

        vm.prank(stranger);
        vm.expectRevert(ISingleReleaseEscrow.OnlyServiceProviderCanChangeMilestoneStatus.selector);
        escrow.changeMilestoneStatus(_status(0, "Done", false, ""));

        vm.startPrank(provider);
        vm.expectRevert(ISingleReleaseEscrow.BatchMilestoneUpdateEmpty.selector);
        escrow.changeMilestoneStatus(new ISingleReleaseEscrow.MilestoneStatusUpdate[](0));
        vm.expectRevert(ISingleReleaseEscrow.EmptyMilestoneStatus.selector);
        escrow.changeMilestoneStatus(_status(0, "", false, ""));
        vm.expectRevert(ISingleReleaseEscrow.MilestoneToUpdateDoesNotExist.selector);
        escrow.changeMilestoneStatus(_status(2, "Done", false, ""));
        vm.expectRevert(ISingleReleaseEscrow.StringTooLong.selector);
        escrow.changeMilestoneStatus(_status(0, "Done", true, string(new bytes(501))));
        vm.stopPrank();
    }

    function test_status_change_rejected_when_released_or_resolved_allowed_while_disputed() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);

        vm.prank(approver);
        escrow.disputeEscrow("scope");
        vm.prank(provider);
        escrow.changeMilestoneStatus(_status(0, "More evidence", true, "ipfs://more"));

        vm.prank(resolver);
        escrow.resolveDispute(_one(receiver), _single(1000 * USDC));
        vm.prank(provider);
        vm.expectRevert(ISingleReleaseEscrow.EscrowAlreadyResolved.selector);
        escrow.changeMilestoneStatus(_status(0, "After", false, ""));

        SingleReleaseEscrow other = _defaultEscrow();
        _fund(other, 1000 * USDC);
        _approveAll(other);
        vm.prank(releaseSigner);
        other.releaseFunds();
        vm.prank(provider);
        vm.expectRevert(ISingleReleaseEscrow.EscrowAlreadyReleased.selector);
        other.changeMilestoneStatus(_status(0, "After", false, ""));
    }

    function test_target_requires_multiple_approvers() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1000 * USDC, 0, 1);
        p.roles.approvers = _two(approver, approver2);
        p.milestones[0].approvals.target = 2;
        SingleReleaseEscrow escrow = _create(p);
        _fund(escrow, 1000 * USDC);

        vm.prank(approver);
        escrow.approveMilestones(_idx(0));
        vm.prank(approver);
        vm.expectRevert(ISingleReleaseEscrow.ApproverAlreadyApprovedMilestone.selector);
        escrow.approveMilestones(_idx(0));

        vm.prank(releaseSigner);
        vm.expectRevert(ISingleReleaseEscrow.EscrowNotCompleted.selector);
        escrow.releaseFunds();

        vm.prank(approver2);
        escrow.approveMilestones(_idx(0));
        ISingleReleaseEscrow.MilestoneApprovals memory a = escrow.getEscrow().milestones[0].approvals;
        assertEq(a.approvalCount, 2);
        assertEq(a.approvedBy[1], approver2);

        vm.prank(approver2);
        vm.expectRevert(ISingleReleaseEscrow.MilestoneHasAlreadyBeenApproved.selector);
        escrow.approveMilestones(_idx(0));

        vm.prank(releaseSigner);
        escrow.releaseFunds();
    }

    function test_approve_milestones_validation() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        uint32[] memory dup = new uint32[](2);

        // Unauthorized fails before the duplicate check.
        vm.prank(stranger);
        vm.expectRevert(ISingleReleaseEscrow.UnauthorizedApprover.selector);
        escrow.approveMilestones(dup);

        vm.startPrank(approver);
        vm.expectRevert(ISingleReleaseEscrow.DuplicateMilestoneIndex.selector);
        escrow.approveMilestones(dup);
        vm.expectRevert(ISingleReleaseEscrow.BatchMilestoneApproveEmpty.selector);
        escrow.approveMilestones(new uint32[](0));
        vm.expectRevert(ISingleReleaseEscrow.MilestoneToApproveDoesNotExist.selector);
        escrow.approveMilestones(_idx(5));
        vm.stopPrank();
    }

    function test_manage_milestones_add_and_update() public {
        SingleReleaseEscrow escrow = _defaultEscrow();

        ISingleReleaseEscrow.Milestone[] memory add = new ISingleReleaseEscrow.Milestone[](1);
        add[0] = _milestone("Third", 1);
        ISingleReleaseEscrow.MilestoneUpdate[] memory upd = new ISingleReleaseEscrow.MilestoneUpdate[](1);
        upd[0] = ISingleReleaseEscrow.MilestoneUpdate({index: 0, setDescription: true, newDescription: "First v2"});

        ISingleReleaseEscrow.MilestoneAddedEntry[] memory added = new ISingleReleaseEscrow.MilestoneAddedEntry[](1);
        added[0] = ISingleReleaseEscrow.MilestoneAddedEntry({index: 2, descriptionHash: sha256(bytes("Third"))});
        ISingleReleaseEscrow.MilestoneUpdatedEntry[] memory updated =
            new ISingleReleaseEscrow.MilestoneUpdatedEntry[](1);
        updated[0] =
            ISingleReleaseEscrow.MilestoneUpdatedEntry({index: 0, newDescriptionHash: sha256(bytes("First v2"))});
        vm.expectEmit(address(escrow));
        emit ISingleReleaseEscrow.MilestonesManaged("ENG-001", admin, 1, 1, added, updated);

        vm.prank(admin);
        escrow.manageMilestones(add, upd);

        ISingleReleaseEscrow.Escrow memory e = escrow.getEscrow();
        assertEq(e.milestones.length, 3);
        assertEq(e.milestones[0].description, "First v2");
        assertEq(e.milestones[2].description, "Third");
    }

    function test_manage_milestones_with_funds() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1 * USDC);

        // Appending is allowed after funding...
        ISingleReleaseEscrow.Milestone[] memory add = new ISingleReleaseEscrow.Milestone[](1);
        add[0] = _milestone("Extra", 1);
        vm.prank(admin);
        escrow.manageMilestones(add, new ISingleReleaseEscrow.MilestoneUpdate[](0));

        // ...editing is not.
        ISingleReleaseEscrow.MilestoneUpdate[] memory upd = new ISingleReleaseEscrow.MilestoneUpdate[](1);
        upd[0] = ISingleReleaseEscrow.MilestoneUpdate({index: 0, setDescription: true, newDescription: "x"});
        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.MilestoneUpdateNotAllowedWithFunds.selector);
        escrow.manageMilestones(new ISingleReleaseEscrow.Milestone[](0), upd);
    }

    function test_manage_milestones_validation() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        ISingleReleaseEscrow.Milestone[] memory none = new ISingleReleaseEscrow.Milestone[](0);
        ISingleReleaseEscrow.MilestoneUpdate[] memory noUpd = new ISingleReleaseEscrow.MilestoneUpdate[](0);

        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.NoMilestoneDefined.selector);
        escrow.manageMilestones(none, noUpd);

        ISingleReleaseEscrow.Milestone[] memory add = new ISingleReleaseEscrow.Milestone[](1);
        add[0] = _milestone("x", 1);
        vm.prank(stranger);
        vm.expectRevert(ISingleReleaseEscrow.OnlyAdminAddressExecuteThisFunction.selector);
        escrow.manageMilestones(add, noUpd);

        add[0] = _milestone(string(new bytes(501)), 1);
        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.StringTooLong.selector);
        escrow.manageMilestones(add, noUpd);

        add[0] = _milestone("x", 2);
        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.TargetExceedsApprovers.selector);
        escrow.manageMilestones(add, noUpd);

        ISingleReleaseEscrow.MilestoneUpdate[] memory upd = new ISingleReleaseEscrow.MilestoneUpdate[](1);
        upd[0] = ISingleReleaseEscrow.MilestoneUpdate({index: 9, setDescription: true, newDescription: "x"});
        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.InvalidMilestoneIndex.selector);
        escrow.manageMilestones(none, upd);
    }

    function _single(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }
}
