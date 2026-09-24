// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./utils/Base.t.sol";
import {ISingleReleaseEscrow} from "../src/interfaces/ISingleReleaseEscrow.sol";
import {SingleReleaseEscrow} from "../src/SingleReleaseEscrow.sol";

contract FundTest is BaseTest {
    function test_fund_escrow_successful_deposit() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        bytes32 h = escrow.escrowHash();

        vm.startPrank(funder);
        usdc.approve(address(escrow), 600 * USDC);
        vm.expectEmit(address(escrow));
        emit ISingleReleaseEscrow.EscrowFunded("ENG-001", funder, 600 * USDC, 600 * USDC);
        escrow.fundEscrow(600 * USDC, h);
        vm.stopPrank();

        _fund(escrow, 400 * USDC);
        assertEq(usdc.balanceOf(address(escrow)), 1000 * USDC);
        assertEq(escrow.fundedAmount(), 1000 * USDC);
    }

    function test_fund_escrow_rejects_zero_mismatch_and_insufficient() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        bytes32 h = escrow.escrowHash();

        vm.startPrank(funder);
        usdc.approve(address(escrow), type(uint256).max);
        vm.expectRevert(ISingleReleaseEscrow.AmountCannotBeZero.selector);
        escrow.fundEscrow(0, h);
        vm.expectRevert(ISingleReleaseEscrow.EscrowPropertiesMismatch.selector);
        escrow.fundEscrow(1, bytes32(uint256(h) ^ 1));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(ISingleReleaseEscrow.InsufficientFundsForEscrowFunding.selector);
        escrow.fundEscrow(1, h);
    }

    function test_fund_hash_changes_with_milestone_state() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        bytes32 before = escrow.escrowHash();
        vm.prank(approver);
        escrow.approveMilestones(_idx(0));
        assertTrue(escrow.escrowHash() != before);

        vm.prank(funder);
        vm.expectRevert(ISingleReleaseEscrow.EscrowPropertiesMismatch.selector);
        escrow.fundEscrow(1, before);
    }

    function test_fund_escrow_with_permit() public {
        (address signer, uint256 pk) = makeAddrAndKey("permitFunder");
        usdc.mint(signer, 100 * USDC);
        SingleReleaseEscrow escrow = _defaultEscrow();
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

    function test_release_funds_successful_flow() public {
        SingleReleaseEscrow escrow = _defaultEscrow(); // 1000 USDC, 5% platform fee
        _fund(escrow, 1000 * USDC);
        _approveAll(escrow);

        vm.expectEmit(address(escrow));
        emit ISingleReleaseEscrow.FundsReleased(
            "ENG-001", releaseSigner, receiver, 1000 * USDC, 50 * USDC, 3 * USDC, 947 * USDC
        );
        vm.prank(releaseSigner);
        escrow.releaseFunds();

        assertEq(usdc.balanceOf(twFee), 3 * USDC);
        assertEq(usdc.balanceOf(platform), 50 * USDC);
        assertEq(usdc.balanceOf(receiver), 947 * USDC);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertTrue(escrow.getEscrow().released);

        vm.prank(releaseSigner);
        vm.expectRevert(ISingleReleaseEscrow.EscrowAlreadyReleased.selector);
        escrow.releaseFunds();
    }

    function test_release_uses_current_fee_recipient() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);
        _approveAll(escrow);
        vm.prank(owner);
        factory.setTrustlessWorkFeeRecipient(stranger);
        vm.prank(releaseSigner);
        escrow.releaseFunds();
        assertEq(usdc.balanceOf(stranger), 3 * USDC);
    }

    function test_release_funds_preconditions() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);

        vm.prank(stranger);
        vm.expectRevert(ISingleReleaseEscrow.OnlyReleaseSignerCanReleaseEarnings.selector);
        escrow.releaseFunds();

        vm.prank(approver);
        escrow.approveMilestones(_idx(0));
        vm.prank(releaseSigner);
        vm.expectRevert(ISingleReleaseEscrow.EscrowNotCompleted.selector);
        escrow.releaseFunds();
    }

    function test_release_requires_balance() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 999 * USDC);
        _approveAll(escrow);
        vm.prank(releaseSigner);
        vm.expectRevert(ISingleReleaseEscrow.EscrowBalanceNotEnoughToSendEarnings.selector);
        escrow.releaseFunds();
    }

    function test_full_flow_init_without_milestones() public {
        SingleReleaseEscrow escrow = _create(_props(100 * USDC, 0, 0));
        _fund(escrow, 100 * USDC);

        vm.prank(releaseSigner);
        vm.expectRevert(ISingleReleaseEscrow.NoMilestoneDefined.selector);
        escrow.releaseFunds();

        ISingleReleaseEscrow.Milestone[] memory add = new ISingleReleaseEscrow.Milestone[](1);
        add[0] = _milestone("Only one", 1);
        vm.prank(admin);
        escrow.manageMilestones(add, new ISingleReleaseEscrow.MilestoneUpdate[](0));

        _approveAll(escrow);
        vm.prank(releaseSigner);
        escrow.releaseFunds();
        assertEq(usdc.balanceOf(receiver), 99.7e6);
        assertEq(usdc.balanceOf(twFee), 0.3e6);
    }

    function test_approve_and_release_milestones_success() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1000 * USDC, 500, 1);
        p.roles.releaseSigners = _one(approver);
        SingleReleaseEscrow escrow = _create(p);
        _fund(escrow, 1000 * USDC);

        vm.prank(approver);
        escrow.approveAndReleaseMilestones(_idx(0));
        assertEq(usdc.balanceOf(receiver), 947 * USDC);
    }

    function test_approve_and_release_milestones_only_approver_fails() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);
        vm.prank(approver);
        vm.expectRevert(ISingleReleaseEscrow.SignerMustBeApproverAndReleaseSigner.selector);
        escrow.approveAndReleaseMilestones(_idx(0));
    }

    function test_dispute_resolver_can_sweep_surplus_after_release() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1100 * USDC);
        _approveAll(escrow);
        vm.prank(releaseSigner);
        escrow.releaseFunds();
        assertEq(usdc.balanceOf(address(escrow)), 100 * USDC);

        // Partial sweep is rejected.
        vm.prank(resolver);
        vm.expectRevert(ISingleReleaseEscrow.DistributionsMustEqualEscrowBalance.selector);
        escrow.withdrawRemainingFunds(_one(funder), _single(50 * USDC));

        uint256 funderBefore = usdc.balanceOf(funder);
        vm.prank(resolver);
        escrow.withdrawRemainingFunds(_one(funder), _single(100 * USDC));
        // 100 - 0.3 TW - 5 platform
        assertEq(usdc.balanceOf(funder) - funderBefore, 94.7e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_withdraw_remaining_funds_requires_processed_escrow() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 10 * USDC);

        vm.prank(resolver);
        vm.expectRevert(ISingleReleaseEscrow.EscrowNotInDispute.selector);
        escrow.withdrawRemainingFunds(_one(funder), _single(10 * USDC));

        vm.prank(provider);
        escrow.disputeEscrow("late");
        vm.prank(resolver);
        vm.expectRevert(ISingleReleaseEscrow.EscrowNotFullyProcessed.selector);
        escrow.withdrawRemainingFunds(_one(funder), _single(10 * USDC));
    }

    function test_dispute_escrow_after_release_is_rejected() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);
        _approveAll(escrow);
        vm.prank(releaseSigner);
        escrow.releaseFunds();
        vm.prank(provider);
        vm.expectRevert(ISingleReleaseEscrow.EscrowAlreadyReleased.selector);
        escrow.disputeEscrow("too late");
    }

    function test_release_with_18_decimal_scale_amounts() public {
        uint256 amount = 20_000_000_000 ether; // 2e28, far above any real USDC balance
        usdc.mint(funder, amount);
        SingleReleaseEscrow escrow = _create(_props(amount, 9900, 1));
        _fund(escrow, amount);
        _approveAll(escrow);
        vm.prank(releaseSigner);
        escrow.releaseFunds();
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(twFee), amount * 30 / 10_000);
        assertEq(usdc.balanceOf(platform), amount * 9900 / 10_000);
        assertEq(usdc.balanceOf(receiver), amount * 70 / 10_000);
    }

    function _single(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }
}
