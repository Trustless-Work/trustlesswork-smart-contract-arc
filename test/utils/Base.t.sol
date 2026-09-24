// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {ISingleReleaseEscrow} from "../../src/interfaces/ISingleReleaseEscrow.sol";
import {SingleReleaseEscrow} from "../../src/SingleReleaseEscrow.sol";
import {SingleReleaseEscrowFactory} from "../../src/SingleReleaseEscrowFactory.sol";

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
    SingleReleaseEscrowFactory internal factory;

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
    address internal funder = makeAddr("funder");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        usdc = new MockUSDC();
        factory = new SingleReleaseEscrowFactory(owner, twFee);
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

    function _milestone(string memory description, uint32 target)
        internal
        pure
        returns (ISingleReleaseEscrow.Milestone memory m)
    {
        m.description = description;
        m.status = "Pending";
        m.approvals.target = target;
    }

    function _roles() internal view returns (ISingleReleaseEscrow.Roles memory r) {
        r.approvers = _one(approver);
        r.serviceProviders = _one(provider);
        r.platform = platform;
        r.releaseSigners = _one(releaseSigner);
        r.disputeResolvers = _one(resolver);
        r.receiver = receiver;
        r.admin = admin;
    }

    function _props(uint256 amount, uint32 platformFee, uint256 milestoneCount)
        internal
        view
        returns (ISingleReleaseEscrow.Escrow memory p)
    {
        p.engagementId = "ENG-001";
        p.title = "Website";
        p.roles = _roles();
        p.description = "Build a website";
        p.amount = amount;
        p.platformFee = platformFee;
        p.token = address(usdc);
        p.milestones = new ISingleReleaseEscrow.Milestone[](milestoneCount);
        for (uint256 i; i < milestoneCount; ++i) {
            p.milestones[i] = _milestone("Milestone", 1);
        }
    }

    function _create(ISingleReleaseEscrow.Escrow memory p) internal returns (SingleReleaseEscrow) {
        return SingleReleaseEscrow(factory.createEscrow(bytes32(++_saltNonce), p));
    }

    function _defaultEscrow() internal returns (SingleReleaseEscrow) {
        return _create(_props(1000 * USDC, 500, 2));
    }

    function _fund(SingleReleaseEscrow escrow, uint256 amount) internal {
        bytes32 h = escrow.escrowHash();
        vm.startPrank(funder);
        usdc.approve(address(escrow), amount);
        escrow.fundEscrow(amount, h);
        vm.stopPrank();
    }

    function _approveAll(SingleReleaseEscrow escrow) internal {
        uint256 n = escrow.getEscrow().milestones.length;
        uint32[] memory idx = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            idx[i] = uint32(i);
        }
        vm.prank(approver);
        escrow.approveMilestones(idx);
    }

    function _amounts(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
