// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {ReputationGate} from "../examples/ReputationGate.sol";

/// @notice End-to-end demo: deploy the registry, attest a freelancer
///         from three attesters, read the one-call profile export,
///         issue + verify a score proof, and gate an action on the
///         result. Runs as a local simulation:
///             forge script script/Demo.s.sol
///         or against a live network with `--rpc-url <url> --broadcast`
///         (the deployer attests as all three attesters in that case —
///         on a real network, use three separate wallets instead).
contract Demo is Script {
    function run() external {
        vm.startBroadcast();

        ReputationRegistry registry = new ReputationRegistry();
        console.log("ReputationRegistry deployed at:", address(registry));

        address alice = makeAddr("alice");
        ReputationRegistry.Category overall = ReputationRegistry
            .Category
            .Overall;

        registry.attest(alice, overall, 90, bytes32("great work"));
        registry.attest(
            alice,
            ReputationRegistry.Category.Quality,
            80,
            bytes32("solid delivery")
        );
        registry.attest(
            alice,
            ReputationRegistry.Category.Timeliness,
            70,
            bytes32("a day late")
        );

        ReputationRegistry.FullProfile memory full = registry
            .getFullProfile(alice);
        console.log("--- Full profile export ---");
        console.log("overall average (x100):", full.profile.overall.average);
        console.log("overall count:", full.profile.overall.count);
        console.log("quality average (x100):", full.profile.quality.average);
        console.log("tier (0 Unranked, 2 Established):", uint8(full.tier));
        console.log("badges earned:", full.badges.length);
        console.log("has snapshot:", full.hasSnapshot);

        ReputationRegistry.ScoreProof memory proof = registry
            .issueScoreProof(alice, 30 days);
        console.log("--- Score proof ---");
        console.log("proof average (x100):", proof.average);
        console.log("proof valid for 30 days, expires at:", proof.expiresAt);
        console.log(
            "proof verifies:",
            registry.verifyScoreProof(proof)
        );

        ReputationGate gate = new ReputationGate(
            address(registry),
            2, // Established
            6000 // average 60+
        );
        console.log("--- Reputation gate ---");
        console.log("gate deployed at:", address(gate));
        console.log("alice eligible:", gate.isEligible(alice));
        gate.gatedAction(alice);
        console.log("gated action accepted for alice");

        vm.stopBroadcast();
    }
}
