// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {SingleReleaseEscrowFactory} from "../src/SingleReleaseEscrowFactory.sol";

/// @notice Deploys the factory (which deploys the escrow implementation).
///   FACTORY_OWNER=0x.. TW_FEE_RECIPIENT=0x.. forge script script/Deploy.s.sol \
///     --rpc-url arc_testnet --private-key $PRIVATE_KEY --broadcast
contract Deploy is Script {
    function run() external returns (SingleReleaseEscrowFactory factory) {
        address owner = vm.envAddress("FACTORY_OWNER");
        address feeRecipient = vm.envAddress("TW_FEE_RECIPIENT");

        vm.startBroadcast();
        factory = new SingleReleaseEscrowFactory(owner, feeRecipient);
        vm.stopBroadcast();

        console.log("SingleReleaseEscrowFactory:", address(factory));
        console.log("SingleReleaseEscrow implementation:", factory.implementation());
    }
}
