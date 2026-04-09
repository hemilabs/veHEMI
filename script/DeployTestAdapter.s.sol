// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {VeHemiAragonAdapter} from "../src/adapter/VeHemiAragonAdapter.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployTestAdapter
/// @notice Deploys the full veHEMI stack + Aragon adapter for testing on Ethereum.
///         Creates 5 test accounts (Alice/Bob/Carol/Dave/Eve) with diverse positions,
///         exercises adapter.delegate() for Aragon-style bulk delegation, sets autoDelegate,
///         seeds the subgraph via refreshVotingPowerBatch, and prints comprehensive
///         verification commands.
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
    uint256 private constant CHECKPOINT_INTERVAL = 1 hours;
    uint256 private constant FUND_AMOUNT = 0.001 ether;

    // Stored during run() so helper functions can access without stack pressure
    MockERC20 internal hemi;
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;
    VeHemiAragonAdapter internal adapter;

    struct TestKeys {
        uint256 aliceKey;
        uint256 bobKey;
        uint256 carolKey;
        uint256 daveKey;
        uint256 eveKey;
    }

    struct TestAddrs {
        address alice;
        address bob;
        address carol;
        address dave;
        address eve;
    }

    function _deriveKeys(uint256 deployerKey) internal pure returns (TestKeys memory k) {
        k.aliceKey = uint256(keccak256(abi.encodePacked(deployerKey, "alice")));
        k.bobKey = uint256(keccak256(abi.encodePacked(deployerKey, "bob")));
        k.carolKey = uint256(keccak256(abi.encodePacked(deployerKey, "carol")));
        k.daveKey = uint256(keccak256(abi.encodePacked(deployerKey, "dave")));
        k.eveKey = uint256(keccak256(abi.encodePacked(deployerKey, "eve")));
    }

    function _addrsFromKeys(TestKeys memory k) internal pure returns (TestAddrs memory a) {
        a.alice = vm.addr(k.aliceKey);
        a.bob = vm.addr(k.bobKey);
        a.carol = vm.addr(k.carolKey);
        a.dave = vm.addr(k.daveKey);
        a.eve = vm.addr(k.eveKey);
    }

    // ─── Deploy ─────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        TestKeys memory keys = _deriveKeys(deployerKey);
        TestAddrs memory addrs = _addrsFromKeys(keys);

        console.log("=== ACCOUNTS ===");
        console.log("Deployer:", deployer);
        console.log("Alice:   ", addrs.alice);
        console.log("Bob:     ", addrs.bob);
        console.log("Carol:   ", addrs.carol);
        console.log("Dave:    ", addrs.dave, " (pure delegatee, no own locks)");
        console.log("Eve:     ", addrs.eve, " (funded but no positions = non-member)");
        console.log("");

        // ── Phase 1: Deploy contracts (deployer broadcast) ──
        vm.startBroadcast(deployerKey);
        _deployContracts(deployer);
        _fundAccounts(addrs);
        _createPositions(deployer, addrs);
        vm.stopBroadcast();

        // ── Phase 2: User-initiated delegations via adapter.delegate() ──
        //    Each user signs their own tx, exercising the Aragon UI path.

        // Carol delegates ALL her power to Dave via the adapter
        // This tests: delegateAllFor, autoDelegate, event relay
        // Dave has no NFTs — pure delegatee (isMember via getVotes > 0)
        vm.broadcast(keys.carolKey);
        adapter.delegate(addrs.dave);
        console.log("Carol -> adapter.delegate(Dave): bulk delegation via Aragon path");

        // Bob delegates ALL his power to Alice via the adapter
        // This tests: adapter.delegate with an account that already has per-token delegation
        // Bob had deployer's lock#3 delegated to him, plus his own self-delegated lock.
        // After this, Alice gets ALL of Bob's aggregate power.
        vm.broadcast(keys.bobKey);
        adapter.delegate(addrs.alice);
        console.log("Bob -> adapter.delegate(Alice): re-delegates all power to Alice");

        // ── Phase 3: Deployer creates one more lock for Bob to test autoDelegate ──
        //    Since Bob called adapter.delegate(Alice), autoDelegate[Bob] = Alice.
        //    A new lock created for Bob should auto-delegate to Alice.
        vm.startBroadcast(deployerKey);

        hemi.mint(deployer, 20e18);
        hemi.approve(address(veHemi), 20e18);
        uint256 autoDelTid = veHemi.createLockFor(20e18, 2 * YEAR, addrs.bob, true, false);
        console.log("New lock for Bob (20 tHEMI, 2yr) tokenId:", autoDelTid);
        console.log("  -> should auto-delegate to Alice (Bob's autoDelegate)");

        // ── Phase 4: Seed the Aragon subgraph via refreshVotingPowerBatch ──
        //    Emit DelegateVotesChanged from the adapter address for all active delegatees.
        //    This ensures the subgraph picks up the initial state.
        console.log("");
        console.log("=== SEEDING SUBGRAPH (refreshVotingPowerBatch) ===");
        address[] memory delegatees = new address[](5);
        delegatees[0] = deployer;
        delegatees[1] = addrs.alice;
        delegatees[2] = addrs.bob;   // should be 0 (delegated everything away)
        delegatees[3] = addrs.carol; // should be 0 (delegated everything to Dave)
        delegatees[4] = addrs.dave;  // should have Carol's power
        adapter.refreshVotingPowerBatch(delegatees);
        console.log("Emitted DelegateVotesChanged from adapter for 5 delegatees");

        vm.stopBroadcast();

        _printKeys(keys);
        _printSummary(deployer, addrs);
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
        delegation.setTrustedAdapter(address(adapter));
        console.log("4. Adapter:          ", address(adapter));
        console.log("   (set as trustedAdapter on VoteDelegation)");
        console.log("");
    }

    function _fundAccounts(TestAddrs memory a) internal {
        console.log("=== FUNDING ACCOUNTS (0.001 ETH each) ===");
        (bool s1,) = a.alice.call{value: FUND_AMOUNT}("");
        require(s1, "fund alice");
        (bool s2,) = a.bob.call{value: FUND_AMOUNT}("");
        require(s2, "fund bob");
        (bool s3,) = a.carol.call{value: FUND_AMOUNT}("");
        require(s3, "fund carol");
        (bool s4,) = a.dave.call{value: FUND_AMOUNT}("");
        require(s4, "fund dave");
        (bool s5,) = a.eve.call{value: FUND_AMOUNT}("");
        require(s5, "fund eve");
        console.log("Done (5 accounts funded).");
        console.log("");
    }

    function _createPositions(address deployer, TestAddrs memory a) internal {
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

        // Per-token delegation from deployer's positions
        delegation.delegate(tid2, a.alice);
        console.log("Delegated lock #2 -> Alice (per-token)");
        delegation.delegate(tid3, a.bob);
        console.log("Delegated lock #3 -> Bob (per-token)");

        // Alice: own lock (auto-self-delegated via createLockFor)
        hemi.mint(deployer, 75e18);
        hemi.approve(address(veHemi), 75e18);
        uint256 tid4 = veHemi.createLockFor(75e18, 3 * YEAR, a.alice, true, false);
        console.log("Alice lock (75 tHEMI, 3yr)          tokenId:", tid4);

        // Bob: own lock (auto-self-delegated via createLockFor)
        hemi.mint(deployer, 50e18);
        hemi.approve(address(veHemi), 50e18);
        uint256 tid5 = veHemi.createLockFor(50e18, 2 * YEAR, a.bob, true, false);
        console.log("Bob lock (50 tHEMI, 2yr)            tokenId:", tid5);

        // Carol: own lock (auto-self-delegated, will later delegate to Dave via adapter)
        hemi.mint(deployer, 30e18);
        hemi.approve(address(veHemi), 30e18);
        uint256 tid6 = veHemi.createLockFor(30e18, YEAR, a.carol, true, false);
        console.log("Carol lock (30 tHEMI, 1yr)          tokenId:", tid6);

        // Dave: NO own locks (pure delegatee — will receive Carol's power via adapter.delegate)
        console.log("Dave: no locks (will be pure delegatee)");

        // Eve: NO locks, NO delegation (non-member for testing rejection)
        console.log("Eve: no locks, no delegation (non-member)");
        console.log("");
    }

    function _printKeys(TestKeys memory k) internal pure {
        console.log("");
        console.log("=== TEST ACCOUNT PRIVATE KEYS (import into wallet) ===");
        console.log("  Alice:", vm.toString(bytes32(k.aliceKey)));
        console.log("  Bob:  ", vm.toString(bytes32(k.bobKey)));
        console.log("  Carol:", vm.toString(bytes32(k.carolKey)));
        console.log("  Dave: ", vm.toString(bytes32(k.daveKey)));
        console.log("  Eve:  ", vm.toString(bytes32(k.eveKey)));
    }

    function _printSummary(address deployer, TestAddrs memory a) internal view {
        // Compute activation timestamp
        uint256 activationTs = ((block.timestamp / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL) + CHECKPOINT_INTERVAL;

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Paste this into Aragon's 'Use existing token' field:");
        console.log("  ADAPTER:", address(adapter));
        console.log("");
        console.log("Contracts:");
        console.log("  tHEMI:      ", address(hemi));
        console.log("  VeHemi:     ", address(veHemi));
        console.log("  Delegation: ", address(delegation));
        console.log("  Adapter:    ", address(adapter));
        console.log("");
        console.log("=== DELEGATION STATE ===");
        console.log("");
        console.log("Per-token delegations (deployer signed):");
        console.log("  Deployer lock#1 -> Deployer (self, auto)");
        console.log("  Deployer lock#2 -> Alice    (per-token)");
        console.log("  Deployer lock#3 -> Bob      (per-token, then Bob re-delegated to Alice)");
        console.log("");
        console.log("Adapter-style bulk delegations (user signed via adapter.delegate):");
        console.log("  Carol -> adapter.delegate(Dave)  : Carol's power goes to Dave");
        console.log("  Bob   -> adapter.delegate(Alice) : Bob's power goes to Alice");
        console.log("    autoDelegate[Carol] = Dave");
        console.log("    autoDelegate[Bob]   = Alice");
        console.log("");
        console.log("autoDelegate test:");
        console.log("  New lock for Bob (20 tHEMI) -> should auto-delegate to Alice");
        console.log("");
        console.log("=== VOTING POWER (after activation) ===");
        console.log("");
        console.log("  Deployer: ~100 veHEMI (lock#1 self-delegated)");
        console.log("  Alice:    ~220 veHEMI (75 own + 50 from deployer + 75 from Bob + 20 autoDelegate)");
        console.log("  Bob:      0 veHEMI   (delegated everything to Alice via adapter)");
        console.log("  Carol:    0 veHEMI   (delegated everything to Dave via adapter)");
        console.log("  Dave:     ~30 veHEMI  (received from Carol, NO own NFTs)");
        console.log("  Eve:      0 veHEMI   (non-member, no NFTs, no delegation)");
        console.log("  Total:    ~350 veHEMI");
        console.log("");
        console.log("=== ACTIVATION TIMING ===");
        console.log("");
        console.log("  Current block.timestamp:", block.timestamp);
        console.log("  Activation timestamp:   ", activationTs);
        console.log("  Seconds until active:   ", activationTs > block.timestamp ? activationTs - block.timestamp : 0);
        console.log("");
        console.log("  Voting power returns 0 until activation timestamp passes.");
        console.log("  Wait until then before creating proposals in Aragon.");
        console.log("");
        console.log("=== WHAT TO TEST ===");
        console.log("");
        console.log("1. isMember checks:");
        console.log("   Alice: member (balanceOf=1, getVotes>0)");
        console.log("   Bob:   member (balanceOf=2, getVotes=0) -- has NFTs but delegated away");
        console.log("   Dave:  member (balanceOf=0, getVotes>0) -- pure delegatee, no NFTs");
        console.log("   Eve:   NOT member (balanceOf=0, getVotes=0)");
        console.log("");
        console.log("2. delegates() return values:");
        console.log("   Deployer: address(0) -- split delegation (lock#1 self, lock#2 Alice, lock#3 re-delegated)");
        console.log("   Alice:    Alice      -- all positions self-delegated");
        console.log("   Bob:      Alice      -- adapter.delegate(Alice) unified all positions");
        console.log("   Carol:    Dave       -- adapter.delegate(Dave) unified all positions");
        console.log("");
        console.log("3. Aragon governance:");
        console.log("   Create proposal as Alice (most power) or Deployer");
        console.log("   Dave can vote with Carol's delegated power");
        console.log("   Eve CANNOT vote (non-member)");
        console.log("");
        console.log("4. Keeper simulation:");
        console.log("   After some time passes, call refreshVotingPowerBatch to update subgraph");
        console.log("");
        console.log("=== VERIFICATION COMMANDS ===");
        console.log("");
        console.log("# Check voting power (after activation):");
        console.log("cast call <ADAPTER> \"getVotes(address)\" <ADDRESS> --rpc-url $ETH_RPC_URL");
        console.log("  Adapter:", address(adapter));
        console.log("  Deployer:", deployer);
        console.log("  Alice:   ", a.alice);
        console.log("  Dave:    ", a.dave);
        console.log("");
        console.log("# Check delegates:");
        console.log("cast call <ADAPTER> \"delegates(address)\" <ADDRESS> --rpc-url $ETH_RPC_URL");
        console.log("  Bob:     ", a.bob);
        console.log("  Carol:   ", a.carol);
        console.log("");
        console.log("# Check autoDelegate:");
        console.log("cast call <DELEGATION> \"autoDelegate(address)\" <ADDRESS> --rpc-url $ETH_RPC_URL");
        console.log("  Delegation:", address(delegation));
        console.log("  Bob:       ", a.bob);
        console.log("  Carol:     ", a.carol);
        console.log("");
        console.log("# Refresh subgraph (keeper simulation):");
        console.log("cast send <ADAPTER> \"refreshVotingPowerBatch(address[])\" \"[addr1,addr2,...]\"");
        console.log("  --private-key $PRIVATE_KEY --rpc-url $ETH_RPC_URL");
        console.log("");
        console.log("# Sweep ETH back after testing:");
        console.log("PRIVATE_KEY=0x... forge script script/DeployTestAdapter.s.sol \\");
        console.log("  --sig \"cleanup()\" --rpc-url $ETH_RPC_URL --broadcast -vvv");
    }

    // ─── Cleanup: sweep ETH back to deployer ────────────────────────────

    function cleanup() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        TestKeys memory keys = _deriveKeys(deployerKey);

        console.log("=== SWEEPING ETH BACK TO DEPLOYER ===");
        console.log("Deployer:", deployer);

        _sweep(keys.aliceKey, deployer, "Alice");
        _sweep(keys.bobKey, deployer, "Bob");
        _sweep(keys.carolKey, deployer, "Carol");
        _sweep(keys.daveKey, deployer, "Dave");
        _sweep(keys.eveKey, deployer, "Eve");

        console.log("Done.");
    }

    function _sweep(uint256 key, address to, string memory label) internal {
        address from = vm.addr(key);
        uint256 bal = from.balance;
        if (bal <= 0.0001 ether) {
            console.log(label, "balance too small to sweep -- skipping");
            return;
        }

        uint256 sendAmount = bal - 0.0001 ether;
        vm.broadcast(key);
        (bool success,) = to.call{value: sendAmount}("");
        require(success, string.concat("sweep ", label));
        console.log(label, "swept back to deployer");
    }
}
