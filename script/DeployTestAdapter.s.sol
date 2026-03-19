// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {VeHemiAragonAdapter} from "../src/adapter/VeHemiAragonAdapter.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployTestAdapter
/// @notice Deploys the full veHEMI stack + Aragon adapter for testing.
///         Derives Alice/Bob/Carol keys deterministically from PRIVATE_KEY,
///         funds them with ETH, and creates veHEMI positions for each.
///
/// Deploy:
///   PRIVATE_KEY=0x... forge script script/DeployTestAdapter.s.sol \
///     --rpc-url $ETH_RPC_URL --broadcast -vvv
///
/// Cleanup (sweep ETH back to deployer):
///   PRIVATE_KEY=0x... forge script script/DeployTestAdapter.s.sol \
///     --sig "cleanup()" --rpc-url $ETH_RPC_URL --broadcast -vvv
contract DeployTestAdapter is Script {
    uint256 private constant YEAR = 365.25 days;
    uint256 private constant FUND_AMOUNT = 0.005 ether;

    // Stored during run() so helper functions can access without stack pressure
    MockERC20 internal hemi;
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;
    VeHemiAragonAdapter internal adapter;

    function _deriveKeys(uint256 deployerKey)
        internal
        pure
        returns (uint256 aliceKey, uint256 bobKey, uint256 carolKey)
    {
        aliceKey = uint256(keccak256(abi.encodePacked(deployerKey, "alice")));
        bobKey = uint256(keccak256(abi.encodePacked(deployerKey, "bob")));
        carolKey = uint256(keccak256(abi.encodePacked(deployerKey, "carol")));
    }

    // ─── Deploy ─────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        (uint256 aliceKey, uint256 bobKey, uint256 carolKey) = _deriveKeys(deployerKey);
        address alice = vm.addr(aliceKey);
        address bob = vm.addr(bobKey);
        address carol = vm.addr(carolKey);

        console.log("=== ACCOUNTS ===");
        console.log("Deployer:", deployer);
        console.log("Alice:   ", alice);
        console.log("Bob:     ", bob);
        console.log("Carol:   ", carol);
        console.log("");

        vm.startBroadcast(deployerKey);

        _deployContracts(deployer);
        _fundAccounts(alice, bob, carol);
        _createPositions(deployer, alice, bob, carol);

        vm.stopBroadcast();

        _printKeys(aliceKey, bobKey, carolKey);
        _printSummary(deployer);
    }

    function _deployContracts(address deployer) internal {
        hemi = new MockERC20("Test HEMI", "tHEMI", 18);
        console.log("1. MockERC20 (tHEMI):", address(hemi));

        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, deployer)
        );
        veHemi = VeHemi(address(proxy));
        console.log("2. VeHemi proxy:     ", address(veHemi));

        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);
        console.log("3. VoteDelegation:   ", address(delegation));

        adapter = new VeHemiAragonAdapter(address(veHemi));
        console.log("4. Adapter:          ", address(adapter));
        console.log("");
    }

    function _fundAccounts(address alice, address bob, address carol) internal {
        console.log("=== FUNDING ACCOUNTS (0.005 ETH each) ===");
        (bool s1,) = alice.call{value: FUND_AMOUNT}("");
        require(s1, "fund alice");
        (bool s2,) = bob.call{value: FUND_AMOUNT}("");
        require(s2, "fund bob");
        (bool s3,) = carol.call{value: FUND_AMOUNT}("");
        require(s3, "fund carol");
        console.log("Done.");
        console.log("");
    }

    function _createPositions(
        address deployer,
        address alice,
        address bob,
        address carol
    ) internal {
        console.log("=== CREATING POSITIONS ===");

        // Deployer: 3 locks (100 + 50 + 25 = 175 tHEMI)
        hemi.mint(deployer, 175e18);
        hemi.approve(address(veHemi), 175e18);

        uint256 tid1 = veHemi.createLock(100e18, 4 * YEAR);
        console.log("Deployer lock #1 (100 tHEMI, 4yr)  tokenId:", tid1);

        uint256 tid2 = veHemi.createLock(50e18, 2 * YEAR);
        console.log("Deployer lock #2 (50 tHEMI, 2yr)   tokenId:", tid2);

        uint256 tid3 = veHemi.createLock(25e18, YEAR);
        console.log("Deployer lock #3 (25 tHEMI, 1yr)   tokenId:", tid3);

        // Delegate lock #2 -> Alice, lock #3 -> Bob
        delegation.delegate(tid2, alice);
        console.log("Delegated lock #2 -> Alice");
        delegation.delegate(tid3, bob);
        console.log("Delegated lock #3 -> Bob");

        // Alice, Bob, Carol: own locks (auto-self-delegated)
        hemi.mint(deployer, 155e18);
        hemi.approve(address(veHemi), 155e18);

        uint256 tid4 = veHemi.createLockFor(75e18, 3 * YEAR, alice, true, false);
        console.log("Alice lock (75 tHEMI, 3yr)          tokenId:", tid4);

        uint256 tid5 = veHemi.createLockFor(50e18, 2 * YEAR, bob, true, false);
        console.log("Bob lock (50 tHEMI, 2yr)            tokenId:", tid5);

        uint256 tid6 = veHemi.createLockFor(30e18, YEAR, carol, true, false);
        console.log("Carol lock (30 tHEMI, 1yr)          tokenId:", tid6);
    }

    function _printKeys(uint256 aliceKey, uint256 bobKey, uint256 carolKey) internal pure {
        console.log("");
        console.log("=== TEST ACCOUNT PRIVATE KEYS (import into wallet) ===");
        console.log("  Alice:", vm.toString(bytes32(aliceKey)));
        console.log("  Bob:  ", vm.toString(bytes32(bobKey)));
        console.log("  Carol:", vm.toString(bytes32(carolKey)));
    }

    function _printSummary(address deployer) internal view {
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Paste this into Aragon's 'Use existing token' field:");
        console.log("  ADAPTER:", address(adapter));
        console.log("");
        console.log("Contracts:");
        console.log("  tHEMI:", address(hemi));
        console.log("  VeHemi:", address(veHemi));
        console.log("  Delegation:", address(delegation));
        console.log("  Adapter:", address(adapter));
        console.log("");
        console.log("Voting power (activates at next UTC midnight):");
        console.log("  Deployer: ~100 veHEMI (self)");
        console.log("  Alice:    ~125 veHEMI (75 own + 50 delegated)");
        console.log("  Bob:      ~75 veHEMI  (50 own + 25 delegated)");
        console.log("  Carol:    ~30 veHEMI  (30 own)");
        console.log("  Total:    ~330 veHEMI");
        console.log("");
        console.log("Check voting power:");
        console.log("  cast call", address(adapter), "\"getVotes(address)\"", deployer);
        console.log("");
        console.log("Sweep ETH back after testing:");
        console.log("  PRIVATE_KEY=0x... forge script script/DeployTestAdapter.s.sol \\");
        console.log("    --sig \"cleanup()\" --rpc-url $ETH_RPC_URL --broadcast -vvv");
    }

    // ─── Cleanup: sweep ETH back to deployer ────────────────────────────

    function cleanup() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        (uint256 aliceKey, uint256 bobKey, uint256 carolKey) = _deriveKeys(deployerKey);

        console.log("=== SWEEPING ETH BACK TO DEPLOYER ===");
        console.log("Deployer:", deployer);

        _sweep(aliceKey, deployer, "Alice");
        _sweep(bobKey, deployer, "Bob");
        _sweep(carolKey, deployer, "Carol");

        console.log("Done.");
    }

    function _sweep(uint256 key, address to, string memory label) internal {
        address from = vm.addr(key);
        uint256 bal = from.balance;
        if (bal <= 0.0003 ether) {
            console.log(label, "balance too small to sweep -- skipping");
            return;
        }

        uint256 sendAmount = bal - 0.0003 ether;
        vm.broadcast(key);
        (bool success,) = to.call{value: sendAmount}("");
        require(success, string.concat("sweep ", label));
        console.log(label, "swept back to deployer");
    }
}
