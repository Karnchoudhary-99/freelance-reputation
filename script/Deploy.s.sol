// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

/// @notice Deploy the ReputationRegistry.
///         Usage: forge script script/Deploy.s.sol --rpc-url <url> --broadcast
contract Deploy is Script {
    function run() external returns (ReputationRegistry registry) {
        vm.startBroadcast();
        registry = new ReputationRegistry();
        vm.stopBroadcast();
        console.log("ReputationRegistry deployed at:", address(registry));
    }
}
