// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./utils/Base.t.sol";
import {ISingleReleaseEscrow} from "../src/interfaces/ISingleReleaseEscrow.sol";
import {ISingleReleaseEscrowFactory} from "../src/interfaces/ISingleReleaseEscrowFactory.sol";
import {SingleReleaseEscrow} from "../src/SingleReleaseEscrow.sol";

contract EscrowTest is BaseTest {
    ////////////////////////
    // Factory / initialize /////
    ////////////////////////

    function test_initialize_escrow() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1000 * USDC, 500, 2);
        address predicted = factory.predictEscrowAddress(address(this), bytes32(uint256(42)));

        vm.expectEmit(predicted);
        emit ISingleReleaseEscrow.EscrowInitialized(p.engagementId, p.amount, p.platformFee, p.token, receiver);
        address escrow = factory.createEscrow(bytes32(uint256(42)), p);

        assertEq(escrow, predicted);
        ISingleReleaseEscrow.Escrow memory stored = SingleReleaseEscrow(escrow).getEscrow();
        assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(p)));
        assertEq(SingleReleaseEscrow(escrow).token(), address(usdc));
    }

    function test_initialize_escrow_without_milestones() public {
        SingleReleaseEscrow escrow = _create(_props(1000 * USDC, 500, 0));
        assertEq(escrow.getEscrow().milestones.length, 0);
    }

    function test_initialize_only_by_factory_and_once() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        ISingleReleaseEscrow.Escrow memory p = _props(1000 * USDC, 500, 1);

        vm.expectRevert(ISingleReleaseEscrow.OnlyFactory.selector);
        escrow.initialize(p);

        vm.prank(address(factory));
        vm.expectRevert(ISingleReleaseEscrow.EscrowAlreadyInitialized.selector);
        escrow.initialize(p);

        // The bare implementation holds no escrow and cannot be initialized.
        SingleReleaseEscrow impl = SingleReleaseEscrow(factory.implementation());
        vm.expectRevert(ISingleReleaseEscrow.EscrowNotFound.selector);
        impl.getEscrow();
        vm.expectRevert(ISingleReleaseEscrow.OnlyFactory.selector);
        impl.initialize(p);
    }

    function test_same_salt_from_different_creators_does_not_collide() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1000 * USDC, 500, 1);
        address a = factory.createEscrow(bytes32(uint256(1)), p);
        vm.prank(stranger);
        address b = factory.createEscrow(bytes32(uint256(1)), p);
        assertTrue(a != b);
    }

    function test_initialize_escrow_platform_fee_too_high() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1000 * USDC, 9901, 1);
        vm.expectRevert(ISingleReleaseEscrow.PlatformFeeTooHigh.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_initialize_rejects_zero_amount_and_empty_roles() public {
        ISingleReleaseEscrow.Escrow memory p = _props(0, 500, 1);
        vm.expectRevert(ISingleReleaseEscrow.AmountCannotBeZero.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.roles.approvers = new address[](0);
        vm.expectRevert(ISingleReleaseEscrow.ApproversListEmpty.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.roles.disputeResolvers = new address[](0);
        vm.expectRevert(ISingleReleaseEscrow.DisputeResolversListEmpty.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_initialize_rejects_zero_addresses() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1, 500, 1);
        p.token = address(0);
        vm.expectRevert(ISingleReleaseEscrow.ZeroAddress.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.roles.observers = _one(address(0));
        vm.expectRevert(ISingleReleaseEscrow.ZeroAddress.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_admin_role_overlap() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1, 500, 1);
        p.roles.approvers = _one(admin);
        vm.expectRevert(ISingleReleaseEscrow.AdminAddressOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.roles.receiver = admin;
        vm.expectRevert(ISingleReleaseEscrow.AdminAddressOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_role_limit_exceeded_and_duplicates() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1, 500, 1);
        p.roles.observers = new address[](6);
        for (uint256 i; i < 6; ++i) {
            p.roles.observers[i] = address(uint160(0x1000 + i));
        }
        vm.expectRevert(ISingleReleaseEscrow.RoleLimitExceeded.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.roles.approvers = _two(approver, approver);
        vm.expectRevert(ISingleReleaseEscrow.DuplicateAddressInRole.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_dispute_resolver_role_overlap() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1, 500, 1);
        p.roles.approvers = _one(resolver);
        vm.expectRevert(ISingleReleaseEscrow.DisputeResolverOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.roles.platform = resolver;
        vm.expectRevert(ISingleReleaseEscrow.DisputeResolverOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.roles.receiver = resolver;
        vm.expectRevert(ISingleReleaseEscrow.DisputeResolverOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_initialize_rejects_bad_milestones() public {
        ISingleReleaseEscrow.Escrow memory p = _props(1, 500, 1);
        p.milestones[0].approvals.target = 0;
        vm.expectRevert(ISingleReleaseEscrow.TargetCannotBeZero.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.milestones[0].approvals.target = 2;
        vm.expectRevert(ISingleReleaseEscrow.TargetExceedsApprovers.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.milestones[0].approvals.approvedBy = _one(approver);
        vm.expectRevert(ISingleReleaseEscrow.FlagsMustBeFalse.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.released = true;
        vm.expectRevert(ISingleReleaseEscrow.FlagsMustBeFalse.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 51);
        vm.expectRevert(ISingleReleaseEscrow.TooManyMilestones.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(1, 500, 1);
        p.title = string(new bytes(101));
        vm.expectRevert(ISingleReleaseEscrow.StringTooLong.selector);
        factory.createEscrow(bytes32(0), p);
    }

    ////////////////////////
    // updateEscrow /////
    ////////////////////////

    function test_update_escrow_before_funding() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        ISingleReleaseEscrow.Escrow memory p = escrow.getEscrow();
        p.title = "New title";
        p.amount = 2000 * USDC;
        p.platformFee = 100;
        p.roles.receiver = stranger;
        // Milestones in the argument are ignored.
        p.milestones = new ISingleReleaseEscrow.Milestone[](0);

        ISingleReleaseEscrow.EscrowPropertyChanges memory changes;
        changes.title = true;
        changes.amount = true;
        changes.platformFee = true;
        changes.roles = true;
        changes.oldAmount = 1000 * USDC;
        changes.newAmount = 2000 * USDC;
        changes.oldPlatformFee = 500;
        changes.newPlatformFee = 100;
        vm.expectEmit(address(escrow));
        emit ISingleReleaseEscrow.EscrowUpdated(p.engagementId, admin, changes);

        vm.prank(admin);
        escrow.updateEscrow(p);

        ISingleReleaseEscrow.Escrow memory stored = escrow.getEscrow();
        assertEq(stored.title, "New title");
        assertEq(stored.amount, 2000 * USDC);
        assertEq(stored.roles.receiver, stranger);
        assertEq(stored.milestones.length, 2);
    }

    function test_update_escrow_access_and_immutables() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        ISingleReleaseEscrow.Escrow memory p = escrow.getEscrow();

        vm.prank(stranger);
        vm.expectRevert(ISingleReleaseEscrow.OnlyAdminAddressExecuteThisFunction.selector);
        escrow.updateEscrow(p);

        p.roles.admin = stranger;
        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.AdminAddressCannotBeChanged.selector);
        escrow.updateEscrow(p);

        p = escrow.getEscrow();
        p.roles.platform = stranger;
        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.PlatformAddressCannotBeChanged.selector);
        escrow.updateEscrow(p);

        p = escrow.getEscrow();
        p.platformFee = 9971;
        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.PlatformFeeTooHigh.selector);
        escrow.updateEscrow(p);
    }

    function test_update_escrow_locked_after_funding() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1 * USDC);

        ISingleReleaseEscrow.Escrow memory p = escrow.getEscrow();
        p.amount = 1;
        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.EscrowPropertiesMismatch.selector);
        escrow.updateEscrow(p);

        // A no-op update is still allowed.
        p = escrow.getEscrow();
        vm.prank(admin);
        escrow.updateEscrow(p);
    }

    function test_update_escrow_blocked_while_disputed() public {
        SingleReleaseEscrow escrow = _defaultEscrow();
        vm.prank(provider);
        escrow.disputeEscrow("late");
        ISingleReleaseEscrow.Escrow memory p = escrow.getEscrow();
        p.dispute.isDisputed = false;
        vm.prank(admin);
        vm.expectRevert(ISingleReleaseEscrow.EscrowOpenedForDisputeResolution.selector);
        escrow.updateEscrow(p);
    }

    ////////////////////////
    // Factory admin / views /////
    ////////////////////////

    function test_fee_recipient_rotation_only_owner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setTrustlessWorkFeeRecipient(stranger);

        vm.prank(owner);
        factory.setTrustlessWorkFeeRecipient(stranger);
        assertEq(factory.trustlessWorkFeeRecipient(), stranger);

        vm.prank(owner);
        vm.expectRevert(ISingleReleaseEscrowFactory.ZeroAddress.selector);
        factory.setTrustlessWorkFeeRecipient(address(0));
    }

    function test_get_multiple_escrow_balances() public {
        SingleReleaseEscrow a = _defaultEscrow();
        SingleReleaseEscrow b = _defaultEscrow();
        _fund(a, 10 * USDC);
        _fund(b, 25 * USDC);

        address[] memory list = _two(address(a), address(b));
        ISingleReleaseEscrowFactory.AddressBalance[] memory balances = factory.getMultipleEscrowBalances(list);
        assertEq(balances[0].balance, 10 * USDC);
        assertEq(balances[1].balance, 25 * USDC);
        assertEq(balances[0].tokenDecimals, 6);

        address[] memory tooMany = new address[](21);
        vm.expectRevert(ISingleReleaseEscrowFactory.TooManyEscrowsRequested.selector);
        factory.getMultipleEscrowBalances(tooMany);
    }
}
