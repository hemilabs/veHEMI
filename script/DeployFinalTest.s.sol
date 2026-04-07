// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {VeHemiAragonAdapter} from "../src/adapter/VeHemiAragonAdapter.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployFinalTest
/// @notice Deploys a clean veHEMI stack with 5 accounts:
///   Deployer: 100 HEMI, 4yr, self-delegated
///   Alice:    200 HEMI, 4yr, self-delegated
///   Bob:      400 HEMI, 4yr, self-delegated
///   Carol:    100 HEMI, 4yr, delegated to Bob
///   John:     100 HEMI, 4yr, delegated to Alice
contract DeployFinalTest is Script {
    uint256 private constant MAX_TIME = 4 * 365.25 days;

    MockERC20 internal hemi;
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;
    VeHemiAragonAdapter internal adapter;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        uint256 aliceKey = uint256(keccak256(abi.encodePacked(deployerKey, "alice")));
        uint256 bobKey = uint256(keccak256(abi.encodePacked(deployerKey, "bob")));
        uint256 carolKey = uint256(keccak256(abi.encodePacked(deployerKey, "carol")));
        uint256 johnKey = uint256(keccak256(abi.encodePacked(deployerKey, "john")));

        console.log("=== ACCOUNTS ===");
        console.log("Deployer:", deployer);
        console.log("Alice:   ", vm.addr(aliceKey));
        console.log("Bob:     ", vm.addr(bobKey));
        console.log("Carol:   ", vm.addr(carolKey));
        console.log("John:    ", vm.addr(johnKey));
        console.log("");

        // ── Deploy contracts + create positions (deployer broadcast) ──
        vm.startBroadcast(deployerKey);
        _deployContracts(deployer);
        _fundAndCreatePositions(deployer, aliceKey, bobKey, carolKey, johnKey);
        vm.stopBroadcast();

        // ── User delegations via adapter ──
        vm.broadcast(carolKey);
        adapter.delegate(vm.addr(bobKey));
        console.log("Carol -> adapter.delegate(Bob)");

        vm.broadcast(johnKey);
        adapter.delegate(vm.addr(aliceKey));
        console.log("John  -> adapter.delegate(Alice)");

        // ── Seed subgraph ──
        vm.startBroadcast(deployerKey);
        _seedAndSummarize(deployer, aliceKey, bobKey, carolKey, johnKey);
        vm.stopBroadcast();
    }

    function _deployContracts(address deployer) internal {
        hemi = new MockERC20("Test HEMI", "tHEMI", 18);
        console.log("1. MockERC20:", address(hemi));

        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, deployer)
        );
        veHemi = VeHemi(address(proxy));
        console.log("2. VeHemi:   ", address(veHemi));

        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);
        console.log("3. Delegation:", address(delegation));

        adapter = new VeHemiAragonAdapter(address(veHemi));
        delegation.setTrustedAdapter(address(adapter));
        console.log("4. Adapter:  ", address(adapter));
        console.log("");
    }

    function _fundAndCreatePositions(
        address deployer,
        uint256 aliceKey,
        uint256 bobKey,
        uint256 carolKey,
        uint256 johnKey
    ) internal {
        address alice = vm.addr(aliceKey);
        address bob = vm.addr(bobKey);
        address carol = vm.addr(carolKey);
        address john = vm.addr(johnKey);

        // Fund accounts
        (bool s1,) = alice.call{value: 0.001 ether}("");
        require(s1);
        (bool s2,) = bob.call{value: 0.001 ether}("");
        require(s2);
        (bool s3,) = carol.call{value: 0.001 ether}("");
        require(s3);
        (bool s4,) = john.call{value: 0.001 ether}("");
        require(s4);

        // Deployer: 100 HEMI, 4yr, self-delegated (via createLock)
        hemi.mint(deployer, 100e18);
        hemi.approve(address(veHemi), 100e18);
        veHemi.createLock(100e18, MAX_TIME);
        console.log("Deployer: 100 HEMI, 4yr (self-delegated)");

        // Alice: 200 HEMI, 4yr
        hemi.mint(deployer, 200e18);
        hemi.approve(address(veHemi), 200e18);
        veHemi.createLockFor(200e18, MAX_TIME, alice, true, false);
        console.log("Alice:    200 HEMI, 4yr (self-delegated)");

        // Bob: 400 HEMI, 4yr
        hemi.mint(deployer, 400e18);
        hemi.approve(address(veHemi), 400e18);
        veHemi.createLockFor(400e18, MAX_TIME, bob, true, false);
        console.log("Bob:      400 HEMI, 4yr (self-delegated)");

        // Carol: 100 HEMI, 4yr (will delegate to Bob via adapter)
        hemi.mint(deployer, 100e18);
        hemi.approve(address(veHemi), 100e18);
        veHemi.createLockFor(100e18, MAX_TIME, carol, true, false);
        console.log("Carol:    100 HEMI, 4yr (will delegate to Bob)");

        // John: 100 HEMI, 4yr (will delegate to Alice via adapter)
        hemi.mint(deployer, 100e18);
        hemi.approve(address(veHemi), 100e18);
        veHemi.createLockFor(100e18, MAX_TIME, john, true, false);
        console.log("John:     100 HEMI, 4yr (will delegate to Alice)");
        console.log("");
    }

    function _seedAndSummarize(
        address deployer,
        uint256 aliceKey,
        uint256 bobKey,
        uint256 carolKey,
        uint256 johnKey
    ) internal {
        address[] memory addrs = new address[](5);
        addrs[0] = deployer;
        addrs[1] = vm.addr(aliceKey);
        addrs[2] = vm.addr(bobKey);
        addrs[3] = vm.addr(carolKey);
        addrs[4] = vm.addr(johnKey);
        adapter.refreshVotingPowerBatch(addrs);
        console.log("Seeded subgraph via refreshVotingPowerBatch");

        uint256 nextEpoch = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Adapter for Aragon:", address(adapter));
        console.log("Epoch interval:    1 hour");
        console.log("Next activation:  ", nextEpoch);
        console.log("Seconds to wait:  ", nextEpoch > block.timestamp ? nextEpoch - block.timestamp : 0);
        console.log("");
        console.log("Expected voting power (after activation):");
        console.log("  Deployer: ~100 veHEMI");
        console.log("  Alice:    ~300 veHEMI (200 own + 100 from John)");
        console.log("  Bob:      ~500 veHEMI (400 own + 100 from Carol)");
        console.log("  Carol:    0 (delegated to Bob)");
        console.log("  John:     0 (delegated to Alice)");
        console.log("");
        console.log("=== PRIVATE KEYS ===");
        console.log("  Alice:", vm.toString(bytes32(aliceKey)));
        console.log("  Bob:  ", vm.toString(bytes32(bobKey)));
        console.log("  Carol:", vm.toString(bytes32(carolKey)));
        console.log("  John: ", vm.toString(bytes32(johnKey)));
    }
}
