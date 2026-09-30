// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {MultiReleaseEscrowFactory} from "../src/MultiReleaseEscrowFactory.sol";

/// @notice Deploys the factory (which deploys the escrow implementation).
/// `forge script` deploys and links the MultiReleaseValidation library
/// automatically.
///   FACTORY_OWNER=0x.. TW_FEE_RECIPIENT=0x.. forge script script/Deploy.s.sol \
///     --rpc-url arc_testnet --private-key $PRIVATE_KEY --broadcast
contract Deploy is Script {
    function run() external returns (MultiReleaseEscrowFactory factory) {
        address owner = vm.envAddress("FACTORY_OWNER");
        address feeRecipient = vm.envAddress("TW_FEE_RECIPIENT");

        vm.startBroadcast();
        factory = new MultiReleaseEscrowFactory(owner, feeRecipient);
        vm.stopBroadcast();

        console.log("MultiReleaseEscrowFactory:", address(factory));
        console.log("MultiReleaseEscrow implementation:", factory.implementation());
    }
}
