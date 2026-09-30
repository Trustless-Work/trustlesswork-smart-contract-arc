// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./utils/Base.t.sol";
import {IMultiReleaseEscrow} from "../src/interfaces/IMultiReleaseEscrow.sol";
import {MultiReleaseEscrow} from "../src/MultiReleaseEscrow.sol";

contract FundTest is BaseTest {
    function test_fund_escrow_successful_deposit() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        bytes32 h = escrow.escrowHash();

        vm.startPrank(funder);
        usdc.approve(address(escrow), 600 * USDC);
        vm.expectEmit(address(escrow));
        emit IMultiReleaseEscrow.EscrowFunded("ENG-001", funder, 600 * USDC, 600 * USDC);
        escrow.fundEscrow(600 * USDC, h);
        vm.stopPrank();

        _fund(escrow, 400 * USDC);
        assertEq(usdc.balanceOf(address(escrow)), 1000 * USDC);
        assertEq(escrow.fundedAmount(), 1000 * USDC);
    }

    function test_fund_escrow_rejects_zero_mismatch_and_insufficient() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        bytes32 h = escrow.escrowHash();

        vm.startPrank(funder);
        usdc.approve(address(escrow), type(uint256).max);
        vm.expectRevert(IMultiReleaseEscrow.AmountCannotBeZero.selector);
        escrow.fundEscrow(0, h);
        vm.expectRevert(IMultiReleaseEscrow.EscrowPropertiesMismatch.selector);
        escrow.fundEscrow(1, bytes32(uint256(h) ^ 1));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.InsufficientFundsForEscrowFunding.selector);
        escrow.fundEscrow(1, h);
    }

    function test_fund_escrow_with_permit() public {
        (address signer, uint256 pk) = makeAddrAndKey("permitFunder");
        usdc.mint(signer, 100 * USDC);
        MultiReleaseEscrow escrow = _defaultEscrow();
        bytes32 h = escrow.escrowHash();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(escrow),
                100 * USDC,
                usdc.nonces(signer),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));

        vm.prank(signer);
        escrow.fundEscrowWithPermit(100 * USDC, h, deadline, v, r, s);
        assertEq(usdc.balanceOf(address(escrow)), 100 * USDC);
    }

    function test_release_single_milestone_pays_its_own_receiver() public {
        MultiReleaseEscrow escrow = _defaultEscrow(); // 600 → receiver, 400 → receiver2, 5%
        _fund(escrow, 1000 * USDC);
        _approve(escrow, _idx(1));

        IMultiReleaseEscrow.MilestonePayout[] memory payouts = new IMultiReleaseEscrow.MilestonePayout[](1);
        payouts[0] = IMultiReleaseEscrow.MilestonePayout({
            index: 1,
            receiver: receiver2,
            amount: 400 * USDC,
            platformFee: 20 * USDC,
            trustlessWorkFee: 1.2e6,
            netAmount: 378.8e6
        });
        vm.expectEmit(address(escrow));
        emit IMultiReleaseEscrow.FundsReleased("ENG-001", releaseSigner, payouts);
        _release(escrow, _idx(1));

        assertEq(usdc.balanceOf(receiver2), 378.8e6);
        assertEq(usdc.balanceOf(receiver), 0);
        assertEq(usdc.balanceOf(platform), 20 * USDC);
        assertEq(usdc.balanceOf(twFee), 1.2e6);
        assertEq(usdc.balanceOf(address(escrow)), 600 * USDC);

        IMultiReleaseEscrow.Escrow memory e = escrow.getEscrow();
        assertTrue(e.milestones[1].released);
        assertFalse(e.milestones[0].released);
    }

    function test_batch_release_partial_then_full() public {
        MultiReleaseEscrow escrow = _create(_propsWith(0, 3)); // 3 × 1 USDC, no platform fee
        _fund(escrow, 3 * USDC);
        _approve(escrow, _idx(0, 2));
        _release(escrow, _idx(0, 2));
        assertEq(usdc.balanceOf(receiver), 2 * 0.997e6);

        vm.prank(releaseSigner);
        vm.expectRevert(IMultiReleaseEscrow.EscrowNotCompleted.selector);
        escrow.releaseFunds(_idx(1));

        _approve(escrow, _idx(1));
        _release(escrow, _idx(1));
        assertEq(usdc.balanceOf(receiver), 3 * 0.997e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_release_validation() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);
        _approve(escrow, _idx(0));

        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.OnlyReleaseSignerCanReleaseEarnings.selector);
        escrow.releaseFunds(_idx(0));

        vm.startPrank(releaseSigner);
        vm.expectRevert(IMultiReleaseEscrow.ReleaseMilestonesEmpty.selector);
        escrow.releaseFunds(new uint32[](0));
        // test_release_funds_rejects_oversized_indices_vector
        vm.expectRevert(IMultiReleaseEscrow.BatchTooLarge.selector);
        escrow.releaseFunds(new uint32[](3));
        vm.expectRevert(IMultiReleaseEscrow.DuplicateMilestoneIndex.selector);
        escrow.releaseFunds(_idx(0, 0));
        vm.expectRevert(IMultiReleaseEscrow.InvalidMilestoneIndex.selector);
        escrow.releaseFunds(_idx(7));
        vm.expectRevert(IMultiReleaseEscrow.EscrowNotCompleted.selector);
        escrow.releaseFunds(_idx(0, 1));
        escrow.releaseFunds(_idx(0));
        vm.expectRevert(IMultiReleaseEscrow.MilestoneAlreadyReleased.selector);
        escrow.releaseFunds(_idx(0));
        vm.stopPrank();
    }

    function test_release_requires_balance_for_the_batch() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 700 * USDC);
        _approve(escrow, _idx(0, 1));

        vm.prank(releaseSigner);
        vm.expectRevert(IMultiReleaseEscrow.EscrowBalanceNotEnoughToSendEarnings.selector);
        escrow.releaseFunds(_idx(0, 1));

        // Each milestone alone is covered.
        _release(escrow, _idx(0));
        assertEq(usdc.balanceOf(address(escrow)), 100 * USDC);
    }

    function test_approve_and_release_milestones_success() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        p.roles.releaseSigners = _one(approver);
        MultiReleaseEscrow escrow = _create(p);
        _fund(escrow, 1000 * USDC);

        vm.prank(approver);
        escrow.approveAndReleaseMilestones(_idx(0));
        assertEq(usdc.balanceOf(receiver), 568.2e6);
        assertFalse(escrow.getEscrow().milestones[1].released);
    }

    function test_approve_and_release_milestones_only_approver_fails() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);
        vm.prank(approver);
        vm.expectRevert(IMultiReleaseEscrow.SignerMustBeApproverAndReleaseSigner.selector);
        escrow.approveAndReleaseMilestones(_idx(0));
    }

    function test_full_flow_init_without_milestones() public {
        MultiReleaseEscrow escrow = _create(_propsWith(0, 0));
        IMultiReleaseEscrow.Milestone[] memory add = new IMultiReleaseEscrow.Milestone[](1);
        add[0] = _milestone("Only one", 100 * USDC, receiver);
        vm.prank(admin);
        escrow.manageMilestones(add, new IMultiReleaseEscrow.MilestoneUpdate[](0));

        _fund(escrow, 100 * USDC);
        _approve(escrow, _idx(0));
        _release(escrow, _idx(0));
        assertEq(usdc.balanceOf(receiver), 99.7e6);
        assertEq(usdc.balanceOf(twFee), 0.3e6);
    }

    function test_dispute_resolver_can_sweep_surplus_after_release() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1100 * USDC);
        _approve(escrow, _idx(0, 1));
        _release(escrow, _idx(0, 1));
        assertEq(usdc.balanceOf(address(escrow)), 100 * USDC);

        // test_withdraw_remaining_funds_rejects_partial_withdrawal
        vm.prank(resolver);
        vm.expectRevert(IMultiReleaseEscrow.DistributionsMustEqualEscrowBalance.selector);
        escrow.withdrawRemainingFunds(_one(funder), _amounts(50 * USDC));

        uint256 funderBefore = usdc.balanceOf(funder);
        vm.prank(resolver);
        escrow.withdrawRemainingFunds(_one(funder), _amounts(100 * USDC));
        assertEq(usdc.balanceOf(funder) - funderBefore, 94.7e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_withdraw_remaining_funds_requires_every_milestone_processed() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);

        vm.prank(resolver);
        vm.expectRevert(IMultiReleaseEscrow.EscrowNotInDispute.selector);
        escrow.withdrawRemainingFunds(_one(funder), _amounts(1000 * USDC));

        _approve(escrow, _idx(0));
        _release(escrow, _idx(0));
        _dispute(escrow, _idx(1));
        vm.prank(resolver);
        vm.expectRevert(IMultiReleaseEscrow.EscrowNotFullyProcessed.selector);
        escrow.withdrawRemainingFunds(_one(funder), _amounts(400 * USDC));
    }

    function test_release_with_18_decimal_scale_amounts() public {
        uint256 amount = 20_000_000_000 ether;
        usdc.mint(funder, amount);
        IMultiReleaseEscrow.Escrow memory p = _propsWith(9900, 1);
        p.milestones[0].amount = amount;
        MultiReleaseEscrow escrow = _create(p);
        _fund(escrow, amount);
        _approve(escrow, _idx(0));
        _release(escrow, _idx(0));
        assertEq(usdc.balanceOf(twFee), amount * 30 / 10_000);
        assertEq(usdc.balanceOf(platform), amount * 9900 / 10_000);
        assertEq(usdc.balanceOf(receiver), amount * 70 / 10_000);
    }
}
