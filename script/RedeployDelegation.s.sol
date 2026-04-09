// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {VeHemiAragonAdapter} from "../src/adapter/VeHemiAragonAdapter.sol";

/// @title RedeployDelegation
/// @notice Deploys a new VeHemiVoteDelegation (with shifted epoch (18:00 UTC boundary)) and adapter
///         on top of the existing VeHemi proxy. Re-delegates all test positions.
///
/// Usage:
///   PRIVATE_KEY=0x... VEHEMI=0x... forge script script/RedeployDelegation.s.sol \
///     --rpc-url $ETH_RPC_URL --broadcast -vvv
contract RedeployDelegation is Script {
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;
    VeHemiAragonAdapter internal adapter;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        veHemi = VeHemi(vm.envAddress("VEHEMI"));

        console.log("=== REDEPLOYING DELEGATION (shifted epoch (18:00 UTC boundary)) ===");
        console.log("VeHemi proxy:", address(veHemi));
        console.log("Deployer:    ", deployer);

        // ── Phase 1: Deploy new delegation + adapter ──
        vm.startBroadcast(deployerKey);
        _deployAndConfigure(deployer);
        vm.stopBroadcast();

        // ── Phase 2: User delegations via adapter.delegate() ──
        _userDelegations(deployerKey);

        // ── Phase 3: Seed subgraph + print summary ──
        vm.startBroadcast(deployerKey);
        _seedAndSummarize(deployer, deployerKey);
        vm.stopBroadcast();
    }

    function _deployAndConfigure(address deployer) internal {
        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);
        console.log("New VoteDelegation:", address(delegation));

        adapter = new VeHemiAragonAdapter(address(veHemi));
        delegation.setTrustedAdapter(address(adapter));
        console.log("New Adapter:       ", address(adapter));

        // Re-delegate deployer's per-token delegations
        address alice = vm.addr(uint256(keccak256(abi.encodePacked(uint256(0), "alice"))));
        // We need the actual deployer key to derive alice — use tokenOfOwnerByIndex directly
        uint256 tid2 = veHemi.tokenOfOwnerByIndex(deployer, 1);
        delegation.delegate(tid2, vm.addr(_deriveKey(msg.sender, "alice")));
        console.log("Deployer lock#2 -> Alice, tokenId:", tid2);

        uint256 tid3 = veHemi.tokenOfOwnerByIndex(deployer, 2);
        delegation.delegate(tid3, vm.addr(_deriveKey(msg.sender, "bob")));
        console.log("Deployer lock#3 -> Bob, tokenId:", tid3);
    }

    function _deriveKey(address, string memory name) internal view returns (uint256) {
        // We can't recover the deployer key here; use envUint
        return uint256(keccak256(abi.encodePacked(vm.envUint("PRIVATE_KEY"), name)));
    }

    function _userDelegations(uint256 deployerKey) internal {
        uint256 carolKey = uint256(keccak256(abi.encodePacked(deployerKey, "carol")));
        uint256 bobKey = uint256(keccak256(abi.encodePacked(deployerKey, "bob")));
        address alice = vm.addr(uint256(keccak256(abi.encodePacked(deployerKey, "alice"))));
        address dave = vm.addr(uint256(keccak256(abi.encodePacked(deployerKey, "dave"))));

        vm.broadcast(carolKey);
        adapter.delegate(dave);
        console.log("Carol -> adapter.delegate(Dave)");

        vm.broadcast(bobKey);
        adapter.delegate(alice);
        console.log("Bob -> adapter.delegate(Alice)");
    }

    function _seedAndSummarize(address deployer, uint256 deployerKey) internal {
        address alice = vm.addr(uint256(keccak256(abi.encodePacked(deployerKey, "alice"))));
        address bob = vm.addr(uint256(keccak256(abi.encodePacked(deployerKey, "bob"))));
        address carol = vm.addr(uint256(keccak256(abi.encodePacked(deployerKey, "carol"))));
        address dave = vm.addr(uint256(keccak256(abi.encodePacked(deployerKey, "dave"))));

        address[] memory delegatees = new address[](5);
        delegatees[0] = deployer;
        delegatees[1] = alice;
        delegatees[2] = bob;
        delegatees[3] = carol;
        delegatees[4] = dave;
        adapter.refreshVotingPowerBatch(delegatees);
        console.log("Seeded subgraph via refreshVotingPowerBatch");

        uint256 epochOffset = 0; // matches EPOCH_OFFSET in VeHemiVoteDelegation
        uint256 activationTs = (((block.timestamp - epochOffset) / 1 hours) * 1 hours) + 1 hours + epochOffset;

        console.log("");
        console.log("=== DONE ===");
        console.log("Epoch length:       1 hour");
        console.log("Current timestamp: ", block.timestamp);
        console.log("Next activation:   ", activationTs);
        console.log("Seconds to wait:   ", activationTs > block.timestamp ? activationTs - block.timestamp : 0);
        console.log("");
        console.log("NEW Adapter for Aragon:", address(adapter));
    }
}
