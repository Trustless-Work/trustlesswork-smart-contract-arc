// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {IMultiReleaseEscrow} from "../../src/interfaces/IMultiReleaseEscrow.sol";
import {MultiReleaseEscrow} from "../../src/MultiReleaseEscrow.sol";
import {MultiReleaseEscrowFactory} from "../../src/MultiReleaseEscrowFactory.sol";

/// @dev 6-decimal ERC-20 with EIP-2612, mirroring USDC's ERC-20 interface on Arc.
contract MockUSDC is ERC20, ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract BaseTest is Test {
    uint256 internal constant USDC = 1e6;

    uint256 private _saltNonce;

    MockUSDC internal usdc;
    MultiReleaseEscrowFactory internal factory;

    address internal owner = makeAddr("owner");
    address internal twFee = makeAddr("twFee");
    address internal admin = makeAddr("admin");
    address internal approver = makeAddr("approver");
    address internal approver2 = makeAddr("approver2");
    address internal provider = makeAddr("provider");
    address internal platform = makeAddr("platform");
    address internal releaseSigner = makeAddr("releaseSigner");
    address internal resolver = makeAddr("resolver");
    address internal receiver = makeAddr("receiver");
    address internal receiver2 = makeAddr("receiver2");
    address internal funder = makeAddr("funder");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        usdc = new MockUSDC();
        factory = new MultiReleaseEscrowFactory(owner, twFee);
        usdc.mint(funder, 1_000_000 * USDC);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _idx(uint32 a) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](1);
        arr[0] = a;
    }

    function _idx(uint32 a, uint32 b) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _amounts(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _amounts(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _milestone(string memory description, uint256 amount, address to)
        internal
        pure
        returns (IMultiReleaseEscrow.Milestone memory m)
    {
        m.description = description;
        m.status = "Pending";
        m.amount = amount;
        m.receiver = to;
        m.approvals.target = 1;
    }

    function _roles() internal view returns (IMultiReleaseEscrow.Roles memory r) {
        r.approvers = _one(approver);
        r.serviceProviders = _one(provider);
        r.platform = platform;
        r.releaseSigners = _one(releaseSigner);
        r.disputeResolvers = _one(resolver);
        r.admin = admin;
    }

    /// @dev Two milestones: 600 USDC to `receiver`, 400 USDC to `receiver2`.
    function _props(uint32 platformFee) internal view returns (IMultiReleaseEscrow.Escrow memory p) {
        p = _propsWith(platformFee, 0);
        p.milestones = new IMultiReleaseEscrow.Milestone[](2);
        p.milestones[0] = _milestone("Design", 600 * USDC, receiver);
        p.milestones[1] = _milestone("Build", 400 * USDC, receiver2);
    }

    /// @dev `count` milestones of 1 USDC each, all to `receiver`.
    function _propsWith(uint32 platformFee, uint256 count) internal view returns (IMultiReleaseEscrow.Escrow memory p) {
        p.engagementId = "ENG-001";
        p.title = "Website";
        p.roles = _roles();
        p.description = "Build a website";
        p.platformFee = platformFee;
        p.token = address(usdc);
        p.milestones = new IMultiReleaseEscrow.Milestone[](count);
        for (uint256 i; i < count; ++i) {
            p.milestones[i] = _milestone("Milestone", 1 * USDC, receiver);
        }
    }

    function _create(IMultiReleaseEscrow.Escrow memory p) internal returns (MultiReleaseEscrow) {
        return MultiReleaseEscrow(factory.createEscrow(bytes32(++_saltNonce), p));
    }

    /// @dev 1000 USDC over two milestones (600 → receiver, 400 → receiver2), 5% platform fee.
    function _defaultEscrow() internal returns (MultiReleaseEscrow) {
        return _create(_props(500));
    }

    function _fund(MultiReleaseEscrow escrow, uint256 amount) internal {
        bytes32 h = escrow.escrowHash();
        vm.startPrank(funder);
        usdc.approve(address(escrow), amount);
        escrow.fundEscrow(amount, h);
        vm.stopPrank();
    }

    function _approve(MultiReleaseEscrow escrow, uint32[] memory indices) internal {
        vm.prank(approver);
        escrow.approveMilestones(indices);
    }

    function _release(MultiReleaseEscrow escrow, uint32[] memory indices) internal {
        vm.prank(releaseSigner);
        escrow.releaseFunds(indices);
    }

    function _dispute(MultiReleaseEscrow escrow, uint32[] memory indices) internal {
        vm.prank(provider);
        escrow.disputeMilestones(indices, "Not delivered");
    }
}
