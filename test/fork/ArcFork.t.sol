// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ISingleReleaseEscrow} from "../../src/interfaces/ISingleReleaseEscrow.sol";
import {SingleReleaseEscrow} from "../../src/SingleReleaseEscrow.sol";
import {SingleReleaseEscrowFactory} from "../../src/SingleReleaseEscrowFactory.sol";

/// @notice Checks against the real USDC on an Arc testnet fork.
/// Run with: forge test --match-path test/fork/ArcFork.t.sol --fork-url arc_testnet
/// @dev Arc's USDC moves balances through node-level system precompiles
/// (e.g. `0x1800…0001::isBlocklisted`) that Foundry's EVM does not implement,
/// so token transfers cannot run on a local fork. Transfer flows are covered by
/// the unit tests and by `script/E2E.s.sol` broadcast on the live testnet.
contract ArcForkTest is Test {
    IERC20Metadata internal constant USDC = IERC20Metadata(0x3600000000000000000000000000000000000000);
    uint256 internal constant ARC_TESTNET = 5042002;

    function test_fork_usdc_interface_and_escrow_creation() public {
        if (block.chainid != ARC_TESTNET) vm.skip(true);
        assertEq(USDC.decimals(), 6);

        // Native USDC (18 decimals) and the ERC-20 view (6 decimals) share one balance.
        address funder = makeAddr("funder");
        vm.deal(funder, 100 ether);
        assertEq(USDC.balanceOf(funder), 100e6);

        SingleReleaseEscrowFactory factory = new SingleReleaseEscrowFactory(address(this), makeAddr("twFee"));

        ISingleReleaseEscrow.Escrow memory p;
        p.engagementId = "ARC-1";
        p.title = "Arc fork";
        p.description = "Fork test";
        p.amount = 10e6;
        p.platformFee = 500;
        p.token = address(USDC);
        p.roles.approvers = _one(makeAddr("approver"));
        p.roles.serviceProviders = _one(makeAddr("provider"));
        p.roles.platform = makeAddr("platform");
        p.roles.releaseSigners = _one(makeAddr("releaseSigner"));
        p.roles.disputeResolvers = _one(makeAddr("resolver"));
        p.roles.receiver = makeAddr("receiver");
        p.roles.admin = makeAddr("admin");
        p.milestones = new ISingleReleaseEscrow.Milestone[](1);
        p.milestones[0].description = "Deliver";
        p.milestones[0].status = "Pending";
        p.milestones[0].approvals.target = 1;

        address predicted = factory.predictEscrowAddress(address(this), bytes32(0));
        SingleReleaseEscrow escrow = SingleReleaseEscrow(factory.createEscrow(bytes32(0), p));
        assertEq(address(escrow), predicted);
        assertEq(escrow.token(), address(USDC));
        assertEq(escrow.escrowHash(), keccak256(abi.encode(p)));

        address[] memory list = _one(address(escrow));
        assertEq(factory.getMultipleEscrowBalances(list)[0].tokenDecimals, 6);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
