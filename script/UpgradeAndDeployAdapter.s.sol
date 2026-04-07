// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {VeHemiAragonAdapter} from "../src/adapter/VeHemiAragonAdapter.sol";

/// @title UpgradeAndDeployAdapter
/// @notice Production deployment script for Hemi mainnet. Deploys new implementation
///         contracts for VeHemi and VeHemiVoteDelegation, the VeHemiAragonAdapter, and
///         prints the Gnosis Safe transactions required to complete the upgrade.
///
/// This script deploys (permissionlessly):
///   1. New VeHemiVoteDelegation implementation (hourly checkpoints, adapter support)
///   2. New VeHemi implementation (hourly epoch, autoDelegate, MIN_LOCK_FOR_AMOUNT)
///   3. VeHemiAragonAdapter (stateless, immutable)
///
/// After deployment, the Gnosis Safe owner must execute (via ProxyAdmin / direct call):
///   4. ProxyAdmin.upgrade(VeHemiVoteDelegation proxy, new delegation impl)
///   5. ProxyAdmin.upgrade(VeHemi proxy, new VeHemi impl)
///   6. VeHemiVoteDelegation.setTrustedAdapter(adapter address)
///
/// Deploy:
///   PRIVATE_KEY=0x... forge script script/UpgradeAndDeployAdapter.s.sol \
///     --rpc-url https://rpc.hemi.network --broadcast --verify \
///     --verifier blockscout --verifier-url https://explorer.hemi.xyz/api -vvv
contract UpgradeAndDeployAdapter is Script {
    // ── Hemi mainnet addresses ──
    address constant VEHEMI_PROXY = 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89;
    address constant DELEGATION_PROXY = 0xBF5b2f370370494B8A4575962512dd3ea7c29e2d;
    address constant PROXY_ADMIN = 0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F;
    address constant HEMI_TOKEN = 0x99e3dE3817F6081B2568208337ef83295b7f591D;
    address constant SAFE_OWNER = 0x694fA0816999Da16E8783C0f5cDE68c13a33C4e6;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("=== PRE-FLIGHT CHECKS ===");
        console.log("Deployer:         ", deployer);
        console.log("Chain ID:         ", block.chainid);
        console.log("VeHemi proxy:     ", VEHEMI_PROXY);
        console.log("Delegation proxy: ", DELEGATION_PROXY);
        console.log("ProxyAdmin:       ", PROXY_ADMIN);
        console.log("Safe owner:       ", SAFE_OWNER);
        console.log("");

        // Verify VeHemi proxy is live
        (bool ok, bytes memory ret) = VEHEMI_PROXY.staticcall(
            abi.encodeWithSignature("voteDelegation()")
        );
        require(ok && ret.length == 32, "VeHemi.voteDelegation() call failed");
        address currentDelegation = abi.decode(ret, (address));
        require(currentDelegation == DELEGATION_PROXY, "voteDelegation mismatch");
        console.log("VoteDelegation:    OK (matches proxy)");

        // Verify totalVeHemiSupply
        (bool ok2, bytes memory ret2) = VEHEMI_PROXY.staticcall(
            abi.encodeWithSignature("totalVeHemiSupply()")
        );
        require(ok2 && ret2.length == 32, "totalVeHemiSupply call failed");
        uint256 supply = abi.decode(ret2, (uint256));
        require(supply > 0, "totalVeHemiSupply is zero");
        console.log("Total veHEMI:     ", supply);

        // Verify ProxyAdmin ownership
        (bool ok3, bytes memory ret3) = PROXY_ADMIN.staticcall(
            abi.encodeWithSignature("owner()")
        );
        require(ok3 && ret3.length == 32, "ProxyAdmin.owner() call failed");
        address adminOwner = abi.decode(ret3, (address));
        require(adminOwner == SAFE_OWNER, "ProxyAdmin owner mismatch");
        console.log("ProxyAdmin owner:  OK (matches Safe)");
        console.log("");

        // ── Deploy ──
        console.log("=== DEPLOYING ===");
        vm.startBroadcast(deployerKey);

        // 1. New VeHemiVoteDelegation implementation
        VeHemiVoteDelegation newDelegationImpl = new VeHemiVoteDelegation(VEHEMI_PROXY);
        console.log("1. New Delegation impl: ", address(newDelegationImpl));

        // 2. New VeHemi implementation
        VeHemi newVeHemiImpl = new VeHemi(HEMI_TOKEN);
        console.log("2. New VeHemi impl:     ", address(newVeHemiImpl));

        // 3. VeHemiAragonAdapter
        VeHemiAragonAdapter adapter = new VeHemiAragonAdapter(VEHEMI_PROXY);
        console.log("3. Adapter:             ", address(adapter));

        vm.stopBroadcast();

        // ── Post-deploy verification ──
        console.log("");
        console.log("=== POST-DEPLOY VERIFICATION ===");

        // Verify adapter
        require(adapter.veHemi() == VEHEMI_PROXY, "adapter.veHemi mismatch");
        require(adapter.supportsInterface(0xe90fb3f6), "IVotes not supported");
        require(adapter.supportsInterface(0x01ffc9a7), "ERC165 not supported");
        require(adapter.supportsInterface(0xda287a1d), "IERC6372 not supported");
        console.log("Adapter interfaces: OK (IVotes + ERC165 + ERC6372)");
        console.log("Adapter name:       ", adapter.name());
        console.log("Adapter symbol:     ", adapter.symbol());
        console.log("Adapter supply:     ", adapter.totalSupply());
        console.log("");

        // ── Print Gnosis Safe transactions ──
        console.log("=== GNOSIS SAFE TRANSACTIONS (execute in order) ===");
        console.log("");

        // Tx 1: Upgrade VeHemiVoteDelegation
        console.log("--- TX 1: Upgrade VeHemiVoteDelegation ---");
        console.log("  To:       ", PROXY_ADMIN);
        console.log("  Function: upgrade(address,address)");
        console.log("  Args:     ", DELEGATION_PROXY);
        console.log("            ", address(newDelegationImpl));
        bytes memory tx1Data = abi.encodeWithSignature(
            "upgrade(address,address)",
            DELEGATION_PROXY,
            address(newDelegationImpl)
        );
        console.log("  Calldata: ");
        console.logBytes(tx1Data);
        console.log("");

        // Tx 2: Upgrade VeHemi
        console.log("--- TX 2: Upgrade VeHemi ---");
        console.log("  To:       ", PROXY_ADMIN);
        console.log("  Function: upgrade(address,address)");
        console.log("  Args:     ", VEHEMI_PROXY);
        console.log("            ", address(newVeHemiImpl));
        bytes memory tx2Data = abi.encodeWithSignature(
            "upgrade(address,address)",
            VEHEMI_PROXY,
            address(newVeHemiImpl)
        );
        console.log("  Calldata: ");
        console.logBytes(tx2Data);
        console.log("");

        // Tx 3: Set trusted adapter
        console.log("--- TX 3: Set Trusted Adapter ---");
        console.log("  To:       ", DELEGATION_PROXY);
        console.log("  Function: setTrustedAdapter(address)");
        console.log("  Args:     ", address(adapter));
        bytes memory tx3Data = abi.encodeWithSignature(
            "setTrustedAdapter(address)",
            address(adapter)
        );
        console.log("  Calldata: ");
        console.logBytes(tx3Data);
        console.log("");

        // ── Summary ──
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("");
        console.log("Deployed contracts (permissionless, already live):");
        console.log("  Delegation impl: ", address(newDelegationImpl));
        console.log("  VeHemi impl:     ", address(newVeHemiImpl));
        console.log("  Adapter:         ", address(adapter));
        console.log("");
        console.log("Gnosis Safe transactions (execute via Safe UI):");
        console.log("  TX 1: Upgrade VeHemiVoteDelegation proxy -> new impl");
        console.log("  TX 2: Upgrade VeHemi proxy -> new impl");
        console.log("  TX 3: setTrustedAdapter(adapter) on delegation proxy");
        console.log("");
        console.log("IMPORTANT: Execute TX 1 before TX 2.");
        console.log("  TX 1 upgrades the delegation contract (adds autoDelegate, hourly checkpoints).");
        console.log("  TX 2 upgrades VeHemi (adds autoDelegate calls, hourly epoch guard).");
        console.log("  VeHemi's try/catch on autoDelegate() ensures safe behavior if TX 2 runs");
        console.log("  before TX 1, but the recommended order is TX 1 first.");
        console.log("  TX 3 can be executed any time after TX 1.");
        console.log("");
        console.log("After all 3 transactions, the adapter is ready for Aragon DAO creation:");
        console.log("  ADAPTER: ", address(adapter));
        console.log("");
        console.log("Existing delegations are preserved through the proxy upgrade.");
        console.log("Users do NOT need to re-delegate. New delegations will activate");
        console.log("at the next hourly epoch boundary instead of the next midnight.");
        console.log("");
        console.log("=== VERIFICATION COMMANDS ===");
        console.log("");
        console.log("# Verify proxy implementations were upgraded:");
        console.log("# Delegation impl:");
        console.log("cast call <PROXY_ADMIN> \"getProxyImplementation(address)\" <DELEGATION_PROXY> --rpc-url https://rpc.hemi.network");
        console.log("  ProxyAdmin:      ", PROXY_ADMIN);
        console.log("  Delegation proxy:", DELEGATION_PROXY);
        console.log("  Expected impl:   ", address(newDelegationImpl));
        console.log("");
        console.log("# VeHemi impl:");
        console.log("  VeHemi proxy:    ", VEHEMI_PROXY);
        console.log("  Expected impl:   ", address(newVeHemiImpl));
        console.log("");
        console.log("# Verify trustedAdapter is set:");
        console.log("  Expected adapter:", address(adapter));
        console.log("");
        console.log("# Verify adapter works:");
        console.log("  Adapter address: ", address(adapter));
    }
}
