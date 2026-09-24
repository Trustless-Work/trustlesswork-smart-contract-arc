// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./utils/Base.t.sol";
import {ISingleReleaseEscrow} from "../src/interfaces/ISingleReleaseEscrow.sol";
import {SingleReleaseEscrow} from "../src/SingleReleaseEscrow.sol";

contract DisputeTest is BaseTest {
    function _disputed(uint256 funded) internal returns (SingleReleaseEscrow escrow) {
        escrow = _defaultEscrow();
        _fund(escrow, funded);
        vm.prank(approver);
        escrow.disputeEscrow("Work not delivered");
    }

    function test_dispute_escrow_authorized_and_unauthorized() public {
        SingleReleaseEscrow escrow = _defaultEscrow();

        vm.prank(stranger);
        vm.expectRevert(ISingleReleaseEscrow.UnauthorizedToChangeDisputeFlag.selector);
        escrow.disputeEscrow("x");

        vm.prank(resolver);
        vm.expectRevert(ISingleReleaseEscrow.DisputeResolverCannotDisputeTheEscrow.selector);
        escrow.disputeEscrow("x");

        vm.prank(receiver);
        vm.expectRevert(ISingleReleaseEscrow.StringTooLong.selector);
        escrow.disputeEscrow(string(new bytes(501)));

        vm.expectEmit(address(escrow));
        emit ISingleReleaseEscrow.EscrowDisputed("ENG-001", receiver, "Late");
        vm.prank(receiver);
        escrow.disputeEscrow("Late");

        ISingleReleaseEscrow.Dispute memory d = escrow.getEscrow().dispute;
        assertTrue(d.isDisputed);
        assertEq(d.reason, "Late");

        vm.prank(platform);
        vm.expectRevert(ISingleReleaseEscrow.EscrowAlreadyInDispute.selector);
        escrow.disputeEscrow("again");
    }

    function test_release_blocked_while_disputed() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1000 * USDC);
        _approveAll(escrow);
        vm.prank(provider);
        escrow.disputeEscrow("x");
        vm.prank(releaseSigner);
        vm.expectRevert(ISingleReleaseEscrow.EscrowOpenedForDisputeResolution.selector);
        escrow.releaseFunds();
    }

    function test_dispute_resolution_process() public {
        SingleReleaseEscrow escrow = _disputed(1000 * USDC); // 5% platform fee

        ISingleReleaseEscrow.DistributionEntry[] memory net = new ISingleReleaseEscrow.DistributionEntry[](2);
        net[0] = ISingleReleaseEscrow.DistributionEntry({recipient: funder, amount: 378.8e6});
        net[1] = ISingleReleaseEscrow.DistributionEntry({recipient: receiver, amount: 568.2e6});
        vm.expectEmit(address(escrow));
        emit ISingleReleaseEscrow.DisputeResolved("ENG-001", resolver, 50 * USDC, 3 * USDC, net);

        uint256 funderBefore = usdc.balanceOf(funder);
        vm.prank(resolver);
        escrow.resolveDispute(_two(funder, receiver), _amounts(400 * USDC, 600 * USDC));

        assertEq(usdc.balanceOf(funder) - funderBefore, 378.8e6);
        assertEq(usdc.balanceOf(receiver), 568.2e6);
        assertEq(usdc.balanceOf(platform), 50 * USDC);
        assertEq(usdc.balanceOf(twFee), 3 * USDC);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        ISingleReleaseEscrow.Dispute memory d = escrow.getEscrow().dispute;
        assertTrue(d.resolved);
        assertFalse(d.isDisputed);

        _approveAll(escrow);
        vm.prank(releaseSigner);
        vm.expectRevert(ISingleReleaseEscrow.EscrowAlreadyResolved.selector);
        escrow.releaseFunds();
    }

    function test_resolve_dispute_validation() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 100 * USDC);

        vm.prank(resolver);
        vm.expectRevert(ISingleReleaseEscrow.EscrowNotInDispute.selector);
        escrow.resolveDispute(_one(funder), _single(100 * USDC));

        vm.prank(provider);
        escrow.disputeEscrow("x");

        vm.prank(stranger);
        vm.expectRevert(ISingleReleaseEscrow.OnlyDisputeResolverCanExecuteThisFunction.selector);
        escrow.resolveDispute(_one(funder), _single(100 * USDC));

        vm.startPrank(resolver);
        vm.expectRevert(ISingleReleaseEscrow.InsufficientFundsForResolution.selector);
        escrow.resolveDispute(_one(funder), _single(101 * USDC));
        vm.expectRevert(ISingleReleaseEscrow.DistributionsMustEqualEscrowBalance.selector);
        escrow.resolveDispute(_one(funder), _single(99 * USDC));
        vm.expectRevert(ISingleReleaseEscrow.AmountsToBeTransferredShouldBePositive.selector);
        escrow.resolveDispute(_two(funder, receiver), _amounts(100 * USDC, 0));
        vm.expectRevert(ISingleReleaseEscrow.DuplicateDistributionRecipient.selector);
        escrow.resolveDispute(_two(funder, funder), _amounts(50 * USDC, 50 * USDC));
        vm.expectRevert(ISingleReleaseEscrow.DistributionLengthMismatch.selector);
        escrow.resolveDispute(_one(funder), _amounts(50 * USDC, 50 * USDC));
        vm.expectRevert(ISingleReleaseEscrow.ZeroAddress.selector);
        escrow.resolveDispute(_one(address(0)), _single(100 * USDC));
        address[] memory many = new address[](51);
        vm.expectRevert(ISingleReleaseEscrow.TooManyDistributions.selector);
        escrow.resolveDispute(many, new uint256[](51));
        vm.stopPrank();
    }

    function test_resolve_dispute_rounding_edge_case() public {
        SingleReleaseEscrow escrow = _disputed(7); // 7 base units, 3 recipients
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
        escrow.resolveDispute(r, a);

        // Fees floor to 0; every unit is paid out and none is stranded.
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(funder) - funderBefore + usdc.balanceOf(receiver) + usdc.balanceOf(stranger), 7);
    }

    function testFuzz_resolve_dispute_conserves_balance(uint96 a0, uint96 a1, uint96 a2, uint16 fee) public {
        vm.assume(a0 > 0 && a1 > 0 && a2 > 0);
        fee = uint16(bound(fee, 0, 9900));
        uint256 total = uint256(a0) + a1 + a2;
        usdc.mint(funder, total);

        SingleReleaseEscrow escrow = _create(_props(1, fee, 1));
        _fund(escrow, total);
        vm.prank(provider);
        escrow.disputeEscrow("x");

        address[] memory r = new address[](3);
        r[0] = makeAddr("r0");
        r[1] = makeAddr("r1");
        r[2] = makeAddr("r2");
        uint256[] memory a = new uint256[](3);
        a[0] = a0;
        a[1] = a1;
        a[2] = a2;

        vm.prank(resolver);
        escrow.resolveDispute(r, a);

        assertEq(usdc.balanceOf(address(escrow)), 0);
        uint256 paid = usdc.balanceOf(r[0]) + usdc.balanceOf(r[1]) + usdc.balanceOf(r[2]);
        assertEq(paid + usdc.balanceOf(platform) + usdc.balanceOf(twFee), total);
        assertEq(usdc.balanceOf(twFee), total * 30 / 10_000);
        assertEq(usdc.balanceOf(platform), total * fee / 10_000);
    }

    function test_withdraw_after_resolution_sweeps_late_deposits() public {
        SingleReleaseEscrow escrow = _disputed(100 * USDC);
        vm.prank(resolver);
        escrow.resolveDispute(_one(receiver), _single(100 * USDC));

        // Someone sends tokens directly after resolution.
        vm.prank(funder);
        usdc.transfer(address(escrow), 10 * USDC);

        vm.prank(resolver);
        escrow.withdrawRemainingFunds(_one(stranger), _single(10 * USDC));
        assertEq(usdc.balanceOf(stranger), 9.47e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function _single(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }
}
