// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./utils/Base.t.sol";
import {IMultiReleaseEscrow} from "../src/interfaces/IMultiReleaseEscrow.sol";
import {MultiReleaseEscrow} from "../src/MultiReleaseEscrow.sol";

contract DisputeTest is BaseTest {
    function test_dispute_milestones_authorized_and_unauthorized() public {
        MultiReleaseEscrow escrow = _defaultEscrow();

        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.UnauthorizedToChangeDisputeFlag.selector);
        escrow.disputeMilestones(_idx(0), "x");

        vm.prank(resolver);
        vm.expectRevert(IMultiReleaseEscrow.DisputeResolverCannotDisputeTheEscrow.selector);
        escrow.disputeMilestones(_idx(0), "x");

        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.UnauthorizedToChangeDisputeFlag.selector);
        escrow.disputeMilestones(_idx(0), "x");

        vm.prank(approver);
        vm.expectRevert(IMultiReleaseEscrow.StringTooLong.selector);
        escrow.disputeMilestones(_idx(0), string(new bytes(501)));

        vm.expectEmit(address(escrow));
        emit IMultiReleaseEscrow.MilestonesDisputed("ENG-001", platform, "Late", _idx(0, 1));
        vm.prank(platform);
        escrow.disputeMilestones(_idx(0, 1), "Late");

        IMultiReleaseEscrow.Escrow memory e = escrow.getEscrow();
        assertTrue(e.milestones[0].dispute.isDisputed);
        assertEq(e.milestones[1].dispute.reason, "Late");
    }

    function test_receiver_can_only_dispute_its_own_milestones() public {
        MultiReleaseEscrow escrow = _defaultEscrow();

        // test_receiver_cannot_dispute_other_receiver_milestone
        vm.prank(receiver);
        vm.expectRevert(IMultiReleaseEscrow.UnauthorizedToChangeDisputeFlag.selector);
        escrow.disputeMilestones(_idx(0, 1), "x");

        vm.prank(receiver2);
        escrow.disputeMilestones(_idx(1), "Mine");
        assertTrue(escrow.getEscrow().milestones[1].dispute.isDisputed);
        assertFalse(escrow.getEscrow().milestones[0].dispute.isDisputed);
    }

    function test_dispute_milestones_validation() public {
        MultiReleaseEscrow escrow = _defaultEscrow();

        vm.startPrank(approver);
        vm.expectRevert(IMultiReleaseEscrow.BatchMilestoneDisputeEmpty.selector);
        escrow.disputeMilestones(new uint32[](0), "x");
        vm.expectRevert(IMultiReleaseEscrow.TooManyMilestones.selector);
        escrow.disputeMilestones(new uint32[](3), "x");
        vm.expectRevert(IMultiReleaseEscrow.InvalidMilestoneIndex.selector);
        escrow.disputeMilestones(_idx(1, 1), "x");
        // test_dispute_milestones_invalid_index_reverts
        vm.expectRevert(IMultiReleaseEscrow.InvalidMilestoneIndex.selector);
        escrow.disputeMilestones(_idx(0, 9), "x");

        escrow.disputeMilestones(_idx(0), "x");
        // scenario_f_dispute_with_already_disputed_milestone_is_atomic
        vm.expectRevert(IMultiReleaseEscrow.MilestoneAlreadyDisputed.selector);
        escrow.disputeMilestones(_idx(1, 0), "x");
        vm.stopPrank();
        assertFalse(escrow.getEscrow().milestones[1].dispute.isDisputed);
    }

    function test_dispute_blocks_only_its_milestone() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);
        _approve(escrow, _idx(0, 1));
        _dispute(escrow, _idx(1));

        vm.prank(releaseSigner);
        vm.expectRevert(IMultiReleaseEscrow.EscrowOpenedForDisputeResolution.selector);
        escrow.releaseFunds(_idx(1));

        _release(escrow, _idx(0));
        assertEq(usdc.balanceOf(receiver), 568.2e6);

        vm.prank(provider);
        vm.expectRevert(IMultiReleaseEscrow.MilestoneAlreadyReleased.selector);
        escrow.disputeMilestones(_idx(0), "too late");
    }

    function test_dispute_resolution_process() public {
        MultiReleaseEscrow escrow = _defaultEscrow(); // 5% platform fee
        _fund(escrow, 1000 * USDC);
        _dispute(escrow, _idx(1)); // milestone 1: 400 USDC

        IMultiReleaseEscrow.DistributionEntry[] memory net = new IMultiReleaseEscrow.DistributionEntry[](2);
        net[0] = IMultiReleaseEscrow.DistributionEntry({recipient: funder, amount: 94.7e6});
        net[1] = IMultiReleaseEscrow.DistributionEntry({recipient: receiver2, amount: 284.1e6});
        vm.expectEmit(address(escrow));
        emit IMultiReleaseEscrow.DisputeResolved("ENG-001", resolver, _idx(1), 20 * USDC, 1.2e6, net);

        uint256 funderBefore = usdc.balanceOf(funder);
        vm.prank(resolver);
        escrow.resolveDispute(_idx(1), _two(funder, receiver2), _amounts(100 * USDC, 300 * USDC));

        assertEq(usdc.balanceOf(funder) - funderBefore, 94.7e6);
        assertEq(usdc.balanceOf(receiver2), 284.1e6);
        assertEq(usdc.balanceOf(address(escrow)), 600 * USDC); // milestone 0 untouched

        IMultiReleaseEscrow.Dispute memory d = escrow.getEscrow().milestones[1].dispute;
        assertTrue(d.resolved);
        assertFalse(d.isDisputed);

        _approve(escrow, _idx(0, 1));
        vm.prank(releaseSigner);
        vm.expectRevert(IMultiReleaseEscrow.EscrowAlreadyResolved.selector);
        escrow.releaseFunds(_idx(1));
        _release(escrow, _idx(0));
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_resolve_dispute_validation() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);

        vm.prank(resolver);
        vm.expectRevert(IMultiReleaseEscrow.EscrowNotInDispute.selector);
        escrow.resolveDispute(_idx(1), _one(funder), _amounts(400 * USDC));

        _dispute(escrow, _idx(1));

        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.OnlyDisputeResolverCanExecuteThisFunction.selector);
        escrow.resolveDispute(_idx(1), _one(funder), _amounts(400 * USDC));

        vm.startPrank(resolver);
        vm.expectRevert(IMultiReleaseEscrow.EscrowNotInDispute.selector);
        escrow.resolveDispute(new uint32[](0), _one(funder), _amounts(400 * USDC));
        vm.expectRevert(IMultiReleaseEscrow.InvalidMilestoneIndex.selector);
        escrow.resolveDispute(_idx(1, 1), _one(funder), _amounts(400 * USDC));
        vm.expectRevert(IMultiReleaseEscrow.EscrowNotInDispute.selector);
        escrow.resolveDispute(_idx(0, 1), _one(funder), _amounts(1000 * USDC));
        // test_resolve_dispute_rejects_partial_settlement
        vm.expectRevert(IMultiReleaseEscrow.DistributionsMustEqualEscrowBalance.selector);
        escrow.resolveDispute(_idx(1), _one(funder), _amounts(399 * USDC));
        vm.expectRevert(IMultiReleaseEscrow.DuplicateDistributionRecipient.selector);
        escrow.resolveDispute(_idx(1), _two(funder, funder), _amounts(200 * USDC, 200 * USDC));
        vm.expectRevert(IMultiReleaseEscrow.DistributionLengthMismatch.selector);
        escrow.resolveDispute(_idx(1), _one(funder), _amounts(200 * USDC, 200 * USDC));
        vm.stopPrank();
    }

    function test_resolve_dispute_requires_balance() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 300 * USDC);
        _dispute(escrow, _idx(1));
        vm.prank(resolver);
        vm.expectRevert(IMultiReleaseEscrow.InsufficientFundsForResolution.selector);
        escrow.resolveDispute(_idx(1), _one(funder), _amounts(400 * USDC));
    }

    function test_resolve_dispute_rounding_edge_case() public {
        IMultiReleaseEscrow.Escrow memory p = _propsWith(500, 1);
        p.milestones[0].amount = 7;
        MultiReleaseEscrow escrow = _create(p);
        _fund(escrow, 7);
        _dispute(escrow, _idx(0));

        address[] memory r = new address[](3);
        r[0] = funder;
        r[1] = receiver;
        r[2] = stranger;
        uint256[] memory a = new uint256[](3);
        a[0] = 2;
        a[1] = 2;
        a[2] = 3;

        uint256 funderBefore = usdc.balanceOf(funder);
        vm.prank(resolver);
        escrow.resolveDispute(_idx(0), r, a);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(funder) - funderBefore + usdc.balanceOf(receiver) + usdc.balanceOf(stranger), 7);
    }

    function testFuzz_resolve_dispute_conserves_amount(uint96 a0, uint96 a1, uint16 fee) public {
        vm.assume(a0 > 0 && a1 > 0);
        fee = uint16(bound(fee, 0, 9900));
        uint256 total = uint256(a0) + a1;
        usdc.mint(funder, total + 5);

        IMultiReleaseEscrow.Escrow memory p = _propsWith(fee, 2);
        p.milestones[0].amount = total;
        p.milestones[1].amount = 5;
        MultiReleaseEscrow escrow = _create(p);
        _fund(escrow, total + 5);
        _dispute(escrow, _idx(0));

        address r0 = makeAddr("r0");
        address r1 = makeAddr("r1");
        vm.prank(resolver);
        escrow.resolveDispute(_idx(0), _two(r0, r1), _amounts(a0, a1));

        assertEq(usdc.balanceOf(r0) + usdc.balanceOf(r1) + usdc.balanceOf(platform) + usdc.balanceOf(twFee), total);
        assertEq(usdc.balanceOf(address(escrow)), 5); // the other milestone stays
    }

    function test_withdraw_after_mixed_release_and_resolution() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1050 * USDC);
        _approve(escrow, _idx(0));
        _release(escrow, _idx(0));
        _dispute(escrow, _idx(1));
        vm.prank(resolver);
        escrow.resolveDispute(_idx(1), _one(receiver2), _amounts(400 * USDC));
        assertEq(usdc.balanceOf(address(escrow)), 50 * USDC);

        vm.prank(resolver);
        escrow.withdrawRemainingFunds(_one(funder), _amounts(50 * USDC));
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}
