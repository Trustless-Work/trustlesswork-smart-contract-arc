// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {BaseTest} from "./utils/Base.t.sol";
import {IMultiReleaseEscrow} from "../src/interfaces/IMultiReleaseEscrow.sol";
import {IMultiReleaseEscrowFactory} from "../src/interfaces/IMultiReleaseEscrowFactory.sol";
import {MultiReleaseEscrow} from "../src/MultiReleaseEscrow.sol";

/// @dev `execute(bytes)` is how Circle CLI agent wallets reach functions with
/// array or tuple arguments, so these tests run the whole flow through it.
contract ExecuteTest is BaseTest {
    function _status(uint32 index, string memory status, string memory evidence)
        internal
        pure
        returns (IMultiReleaseEscrow.MilestoneStatusUpdate[] memory u)
    {
        u = new IMultiReleaseEscrow.MilestoneStatusUpdate[](1);
        u[0] = IMultiReleaseEscrow.MilestoneStatusUpdate({
            milestoneIndex: index, newStatus: status, setEvidence: true, newEvidence: evidence
        });
    }

    function test_execute_creates_the_escrow_for_the_caller() public {
        IMultiReleaseEscrow.Escrow memory p = _props(0);
        bytes32 salt = keccak256("agent");
        address predicted = factory.predictEscrowAddress(funder, salt);
        bytes memory data = abi.encodeCall(factory.createEscrow, (salt, p));

        vm.expectEmit(address(factory));
        emit IMultiReleaseEscrowFactory.EscrowCreated(predicted, funder, "ENG-001", admin, salt);
        vm.prank(funder);
        bytes memory ret = factory.execute(data);

        assertEq(abi.decode(ret, (address)), predicted);
        assertEq(MultiReleaseEscrow(predicted).getEscrow().milestones.length, 2);
    }

    function test_execute_runs_each_step_as_its_role() public {
        MultiReleaseEscrow escrow = _create(_props(0));
        _fund(escrow, 1000 * USDC);

        vm.prank(provider);
        escrow.execute(abi.encodeCall(escrow.changeMilestoneStatus, (_status(0, "Done", "ipfs://proof"))));
        assertEq(escrow.getEscrow().milestones[0].evidence, "ipfs://proof");

        vm.expectEmit(address(escrow));
        emit IMultiReleaseEscrow.MilestonesApproved("ENG-001", approver, _idx(0));
        vm.prank(approver);
        escrow.execute(abi.encodeCall(escrow.approveMilestones, (_idx(0))));

        vm.prank(releaseSigner);
        escrow.execute(abi.encodeCall(escrow.releaseFunds, (_idx(0))));

        assertTrue(escrow.getEscrow().milestones[0].released);
        assertEq(usdc.balanceOf(receiver), 598_200_000);
    }

    function test_execute_resolves_a_dispute() public {
        MultiReleaseEscrow escrow = _create(_props(0));
        _fund(escrow, 1000 * USDC);

        vm.prank(provider);
        escrow.execute(abi.encodeCall(escrow.disputeMilestones, (_idx(1), "Partial delivery")));
        vm.prank(resolver);
        escrow.execute(
            abi.encodeCall(escrow.resolveDispute, (_idx(1), _two(receiver2, funder), _amounts(300 * USDC, 100 * USDC)))
        );

        assertTrue(escrow.getEscrow().milestones[1].dispute.resolved);
        assertEq(usdc.balanceOf(receiver2), 299_100_000);
        assertEq(usdc.balanceOf(address(escrow)), 600 * USDC);
    }

    function test_execute_keeps_every_caller_check() public {
        MultiReleaseEscrow escrow = _defaultEscrow();
        bytes memory approve = abi.encodeCall(escrow.approveMilestones, (_idx(0)));
        bytes memory init = abi.encodeCall(escrow.initialize, (_props(0)));
        bytes memory setFee = abi.encodeCall(factory.setTrustlessWorkFeeRecipient, (stranger));

        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.UnauthorizedApprover.selector);
        escrow.execute(approve);

        vm.prank(stranger);
        vm.expectRevert(IMultiReleaseEscrow.OnlyFactory.selector);
        escrow.execute(init);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.execute(setFee);

        vm.prank(owner);
        factory.execute(setFee);
        assertEq(factory.trustlessWorkFeeRecipient(), stranger);
    }

    function test_execute_rejects_unknown_calls() public {
        MultiReleaseEscrow escrow = _defaultEscrow();

        vm.expectRevert(Errors.FailedCall.selector);
        escrow.execute(hex"12345678");
        vm.expectRevert(Errors.FailedCall.selector);
        factory.execute("");
    }
}
