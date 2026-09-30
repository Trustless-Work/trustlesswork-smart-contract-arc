// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./utils/Base.t.sol";
import {IMultiReleaseEscrow} from "../src/interfaces/IMultiReleaseEscrow.sol";
import {IMultiReleaseEscrowFactory} from "../src/interfaces/IMultiReleaseEscrowFactory.sol";
import {MultiReleaseEscrow} from "../src/MultiReleaseEscrow.sol";

contract EscrowTest is BaseTest {
    ////////////////////////
    // Factory / initialize /////
    ////////////////////////

    function test_initialize_escrow() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        address predicted = factory.predictEscrowAddress(address(this), bytes32(uint256(42)));

        vm.expectEmit(predicted);
        emit IMultiReleaseEscrow.EscrowInitialized(p.engagementId, 2, 1000 * USDC);
        address escrow = factory.createEscrow(bytes32(uint256(42)), p);

        assertEq(escrow, predicted);
        IMultiReleaseEscrow.Escrow memory stored = MultiReleaseEscrow(escrow).getEscrow();
        assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(p)));
        assertEq(stored.milestones[1].receiver, receiver2);
        assertEq(MultiReleaseEscrow(escrow).token(), address(usdc));
    }

    function test_initialize_escrow_without_milestones() public {
        MultiReleaseEscrow escrow = _create(_propsWith(500, 0));
        assertEq(escrow.getEscrow().milestones.length, 0);
    }

    function test_initialize_only_by_factory_and_once() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        IMultiReleaseEscrow.Escrow memory p = _props(500);

        vm.expectRevert(IMultiReleaseEscrow.OnlyFactory.selector);
        escrow.initialize(p);

        vm.prank(address(factory));
        vm.expectRevert(IMultiReleaseEscrow.EscrowAlreadyInitialized.selector);
        escrow.initialize(p);

        MultiReleaseEscrow impl = MultiReleaseEscrow(factory.implementation());
        vm.expectRevert(IMultiReleaseEscrow.EscrowNotFound.selector);
        impl.getEscrow();
        vm.expectRevert(IMultiReleaseEscrow.OnlyFactory.selector);
        impl.initialize(p);
    }

    function test_same_salt_from_different_creators_does_not_collide() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        address a = factory.createEscrow(bytes32(uint256(1)), p);
        vm.prank(stranger);
        address b = factory.createEscrow(bytes32(uint256(1)), p);
        assertTrue(a != b);
    }

    function test_initialize_escrow_platform_fee_too_high() public {
        vm.expectRevert(IMultiReleaseEscrow.PlatformFeeTooHigh.selector);
        factory.createEscrow(bytes32(0), _props(9901));
    }

    function test_initialize_rejects_zero_amount_and_empty_roles() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        p.milestones[1].amount = 0;
        vm.expectRevert(IMultiReleaseEscrow.AmountCannotBeZero.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(500);
        p.roles.releaseSigners = new address[](0);
        vm.expectRevert(IMultiReleaseEscrow.ReleaseSignersListEmpty.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_initialize_rejects_zero_addresses() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        p.milestones[0].receiver = address(0);
        vm.expectRevert(IMultiReleaseEscrow.ZeroAddress.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(500);
        p.token = address(0);
        vm.expectRevert(IMultiReleaseEscrow.ZeroAddress.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_admin_role_overlap() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        p.roles.serviceProviders = _one(admin);
        vm.expectRevert(IMultiReleaseEscrow.AdminAddressOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);

        // test_admin_cannot_be_milestone_receiver
        p = _props(500);
        p.milestones[1].receiver = admin;
        vm.expectRevert(IMultiReleaseEscrow.AdminAddressOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_admin_can_equal_platform() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        p.roles.platform = admin;
        MultiReleaseEscrow escrow = _create(p);
        assertEq(escrow.getEscrow().roles.platform, admin);
    }

    function test_role_limit_exceeded_and_duplicates() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        p.roles.approvers = new address[](6);
        for (uint256 i; i < 6; ++i) {
            p.roles.approvers[i] = address(uint160(0x1000 + i));
        }
        vm.expectRevert(IMultiReleaseEscrow.RoleLimitExceeded.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(500);
        p.roles.disputeResolvers = _two(resolver, resolver);
        vm.expectRevert(IMultiReleaseEscrow.DuplicateAddressInRole.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_dispute_resolver_role_overlap() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        p.roles.releaseSigners = _one(resolver);
        vm.expectRevert(IMultiReleaseEscrow.DisputeResolverOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);

        // test_dispute_resolver_cannot_equal_platform
        p = _props(500);
        p.roles.platform = resolver;
        vm.expectRevert(IMultiReleaseEscrow.DisputeResolverOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);

        // test_dispute_resolver_cannot_be_milestone_receiver
        p = _props(500);
        p.milestones[0].receiver = resolver;
        vm.expectRevert(IMultiReleaseEscrow.DisputeResolverOverlapsWithOtherRole.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_initialize_rejects_milestones_with_runtime_state() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        p.milestones[0].released = true;
        vm.expectRevert(IMultiReleaseEscrow.FlagsMustBeFalse.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(500);
        p.milestones[1].dispute.isDisputed = true;
        vm.expectRevert(IMultiReleaseEscrow.FlagsMustBeFalse.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(500);
        p.milestones[1].approvals.approvedBy = _one(approver);
        vm.expectRevert(IMultiReleaseEscrow.FlagsMustBeFalse.selector);
        factory.createEscrow(bytes32(0), p);
    }

    function test_initialize_rejects_bad_milestones() public {
        IMultiReleaseEscrow.Escrow memory p = _props(500);
        p.milestones[0].approvals.target = 0;
        vm.expectRevert(IMultiReleaseEscrow.TargetCannotBeZero.selector);
        factory.createEscrow(bytes32(0), p);

        p = _props(500);
        p.milestones[0].approvals.target = 2;
        vm.expectRevert(IMultiReleaseEscrow.TargetExceedsApprovers.selector);
        factory.createEscrow(bytes32(0), p);

        vm.expectRevert(IMultiReleaseEscrow.TooManyMilestones.selector);
        factory.createEscrow(bytes32(0), _propsWith(500, 51));

        p = _props(500);
        p.milestones[1].evidence = string(new bytes(501));
        vm.expectRevert(IMultiReleaseEscrow.StringTooLong.selector);
        factory.createEscrow(bytes32(0), p);
    }

    ////////////////////////
    // updateEscrow /////
    ////////////////////////

    function test_update_escrow_before_funding() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        IMultiReleaseEscrow.Escrow memory p = escrow.getEscrow();
        p.title = "New title";
        p.platformFee = 100;
        p.roles.observers = _one(stranger);
        p.milestones = new IMultiReleaseEscrow.Milestone[](0); // ignored

        IMultiReleaseEscrow.EscrowPropertyChanges memory changes;
        changes.title = true;
        changes.platformFee = true;
        changes.roles = true;
        changes.oldPlatformFee = 500;
        changes.newPlatformFee = 100;
        vm.expectEmit(address(escrow));
        emit IMultiReleaseEscrow.EscrowUpdated(p.engagementId, admin, changes);

        vm.prank(admin);
        escrow.updateEscrow(p);

        IMultiReleaseEscrow.Escrow memory stored = escrow.getEscrow();
        assertEq(stored.title, "New title");
        assertEq(stored.platformFee, 100);
        assertEq(stored.milestones.length, 2);
    }

    function test_update_escrow_access_and_immutables() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        IMultiReleaseEscrow.Escrow memory p = escrow.getEscrow();

        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.OnlyAdminAddressExecuteThisFunction.selector);
        escrow.updateEscrow(p);

        p.roles.admin = stranger;
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.AdminAddressCannotBeChanged.selector);
        escrow.updateEscrow(p);

        p = escrow.getEscrow();
        p.roles.platform = stranger;
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.PlatformAddressCannotBeChanged.selector);
        escrow.updateEscrow(p);

        p = escrow.getEscrow();
        p.platformFee = 9971;
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.PlatformFeeTooHigh.selector);
        escrow.updateEscrow(p);
    }

    function test_update_escrow_locked_after_funding() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _fund(escrow, 1 * USDC);

        IMultiReleaseEscrow.Escrow memory p = escrow.getEscrow();
        p.receiverMemo = 7;
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.EscrowPropertiesMismatch.selector);
        escrow.updateEscrow(p);

        // A no-op update is still allowed.
        p = escrow.getEscrow();
        vm.prank(admin);
        escrow.updateEscrow(p);
    }

    function test_update_escrow_blocked_while_a_milestone_is_disputed() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        _dispute(escrow, _idx(1));
        IMultiReleaseEscrow.Escrow memory p = escrow.getEscrow();
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.EscrowOpenedForDisputeResolution.selector);
        escrow.updateEscrow(p);
    }

    /// Soroban checks the overlap rules against the milestones in the argument,
    /// which update discards. The port checks the stored ones, so look-alike
    /// milestones cannot hide a resolver that is also a real receiver.
    function test_update_checks_overlap_against_stored_milestones() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        IMultiReleaseEscrow.Escrow memory p = escrow.getEscrow();
        p.roles.disputeResolvers = _one(receiver2); // receiver of milestone 1
        p.milestones = new IMultiReleaseEscrow.Milestone[](0);
        vm.prank(admin);
        vm.expectRevert(IMultiReleaseEscrow.DisputeResolverOverlapsWithOtherRole.selector);
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
    }

    function test_get_multiple_escrow_balances() public {
        MultiReleaseEscrow a = _defaultEscrow();
        MultiReleaseEscrow b = _defaultEscrow();
        _fund(a, 10 * USDC);
        _fund(b, 25 * USDC);

        IMultiReleaseEscrowFactory.AddressBalance[] memory balances =
            factory.getMultipleEscrowBalances(_two(address(a), address(b)));
        assertEq(balances[0].balance, 10 * USDC);
        assertEq(balances[1].balance, 25 * USDC);
        assertEq(balances[1].tokenDecimals, 6);
    }
}
