// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {VeHemiAragonAdapter} from "../src/adapter/VeHemiAragonAdapter.sol";

/// @title DeployAdapter
/// @notice Production deployment script for VeHemiAragonAdapter on Hemi mainnet.
///         Deploys ONLY the adapter — all other contracts (HEMI, VeHemi,
///         VeHemiVoteDelegation) are already live.
///
/// Required env vars:
///   PRIVATE_KEY   – deployer private key
///   VEHEMI        – address of the VeHemi proxy on Hemi mainnet
///                   (default: 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89)
///
/// Deploy:
///   PRIVATE_KEY=0x... forge script script/DeployAdapter.s.sol \
///     --rpc-url https://rpc.hemi.network --broadcast --verify -vvv
///
/// Verify only (if verification failed during deploy):
///   forge verify-contract <ADAPTER_ADDRESS> \
///     src/adapter/VeHemiAragonAdapter.sol:VeHemiAragonAdapter \
///     --constructor-args $(cast abi-encode "constructor(address)" 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89) \
///     --rpc-url https://rpc.hemi.network --verifier blockscout \
///     --verifier-url https://explorer.hemi.xyz/api
contract DeployAdapter is Script {
    // Default VeHemi proxy address on Hemi mainnet
    address constant DEFAULT_VEHEMI = 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address veHemi = vm.envOr("VEHEMI", DEFAULT_VEHEMI);

        console.log("=== PRE-FLIGHT CHECKS ===");
        console.log("Deployer:  ", deployer);
        console.log("VeHemi:    ", veHemi);
        console.log("Chain ID:  ", block.chainid);
        console.log("");

        // --- Pre-flight: verify VeHemi is a live contract ---
        // Read voteDelegation to confirm VeHemi is responding
        (bool ok, bytes memory ret) = veHemi.staticcall(
            abi.encodeWithSignature("voteDelegation()")
        );
        require(ok && ret.length == 32, "VeHemi.voteDelegation() call failed -- wrong address?");
        address voteDelegation = abi.decode(ret, (address));
        require(voteDelegation != address(0), "VeHemi.voteDelegation() returned zero -- not initialized?");
        console.log("VoteDelegation (live): ", voteDelegation);

        // Read totalVeHemiSupply to confirm real positions exist
        (bool ok2, bytes memory ret2) = veHemi.staticcall(
            abi.encodeWithSignature("totalVeHemiSupply()")
        );
        require(ok2 && ret2.length == 32, "VeHemi.totalVeHemiSupply() call failed");
        uint256 totalSupply = abi.decode(ret2, (uint256));
        console.log("Total veHEMI supply:  ", totalSupply);
        require(totalSupply > 0, "totalVeHemiSupply is zero -- are there any positions?");
        console.log("");

        // --- Deploy ---
        console.log("=== DEPLOYING ADAPTER ===");
        vm.startBroadcast(deployerKey);

        VeHemiAragonAdapter adapter = new VeHemiAragonAdapter(veHemi);

        vm.stopBroadcast();

        // --- Post-deploy verification ---
        console.log("");
        console.log("=== POST-DEPLOY VERIFICATION ===");
        console.log("Adapter:           ", address(adapter));
        console.log("adapter.veHemi():  ", adapter.veHemi());
        console.log("adapter.voteDelegation():", adapter.voteDelegation());
        console.log("adapter.totalSupply():   ", adapter.totalSupply());
        console.log("adapter.name():          ", adapter.name());
        console.log("adapter.symbol():        ", adapter.symbol());
        console.log("adapter.decimals():      ", adapter.decimals());
        console.log("adapter.clock():         ", adapter.clock());
        console.log("adapter.CLOCK_MODE():    ", adapter.CLOCK_MODE());

        // Verify ERC-165
        bytes4 ivotesId = bytes4(keccak256("getVotes(address)"))
            ^ bytes4(keccak256("getPastVotes(address,uint256)"))
            ^ bytes4(keccak256("getPastTotalSupply(uint256)"))
            ^ bytes4(keccak256("delegates(address)"))
            ^ bytes4(keccak256("delegate(address)"))
            ^ bytes4(keccak256("delegateBySig(address,uint256,uint256,uint8,bytes32,bytes32)"));
        require(adapter.supportsInterface(ivotesId), "IVotes interface not supported");
        require(adapter.supportsInterface(0x01ffc9a7), "ERC165 interface not supported");
        console.log("ERC-165 IVotes:    OK");
        console.log("ERC-165 ERC165:    OK");

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Paste this into Aragon's 'Use existing token' field:");
        console.log("  ADAPTER:", address(adapter));
        console.log("");
        console.log("Verify on explorer:");
        console.log("  forge verify-contract", address(adapter));
        console.log("    src/adapter/VeHemiAragonAdapter.sol:VeHemiAragonAdapter");
        console.log("    --constructor-args $(cast abi-encode \"constructor(address)\"", veHemi, ")");
        console.log("    --rpc-url https://rpc.hemi.network --verifier blockscout");
        console.log("    --verifier-url https://explorer.hemi.xyz/api");
        console.log("");
        console.log("Spot-check a known holder's voting power:");
        console.log("  cast call", address(adapter), "\"getVotes(address)\" <HOLDER_ADDRESS> --rpc-url https://rpc.hemi.network");
    }
}
