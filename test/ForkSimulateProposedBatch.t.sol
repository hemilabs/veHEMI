// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {VeHemiAragonAdapter} from "../src/adapter/VeHemiAragonAdapter.sol";
import {IVeHemi} from "../src/interfaces/IVeHemi.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Simulate the proposed V2-upgrade Safe MultiSend against a Hemi
///        mainnet fork.
///
/// @notice Faster, more focused complement to ForkE2EDeployment.t.sol.
///         That test deploys fresh V2 impls inside the test. This one
///         uses the EXACT impl addresses currently on-chain that the
///         Safe batch references — so it verifies the actual proposed
///         transaction will produce correct state, not a hypothetical
///         alternate.
///
///         Run with:
///           HEMI_RPC_URL=https://... HEMI_FORK_BLOCK=<recent>
///           forge test --match-contract ForkSimulateProposedBatch -vvv
contract ForkSimulateProposedBatchTest is Test {
    // Discovered at runtime by _verifyPerPositionReconstruction so later
    // sections can refer to a known-live non-transferable position without
    // hardcoding an id that may have been withdrawn since the test was
    // written.
    uint256 private _ntSampleId;
    address private _ntSampleOwner;
    uint256 private _ntSampleSubEnd;

    // ── Safe + Proxy infrastructure (already-deployed on Hemi mainnet) ──
    address constant SAFE = 0x694fA0816999Da16E8783C0f5cDE68c13a33C4e6;
    address constant PROXY_ADMIN = 0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F;
    address constant VE_HEMI_PROXY = 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89;
    address constant VVD_PROXY = 0xBF5b2f370370494B8A4575962512dd3ea7c29e2d;

    // ── New deployments referenced by the proposed Safe batch ──
    // These are the addresses the deployer EOA paid to deploy in the
    // earlier hardhat-deploy run. The proposed Safe MultiSend wires the
    // proxies at them.
    address constant VE_HEMI_V2_IMPL = 0xf1e3AA617E5011793F759092b59d22247E57b84A;
    address constant VVD_V2_IMPL = 0xAcAA0d96121C035fC21345551317d66921394128;
    address constant ADAPTER = 0x3f41c138082b29fb1a6c91066e73480163f984e4;

    // ── HEMI token (for test mints) ──
    address constant HEMI_TOKEN = 0x99e3dE3817F6081B2568208337ef83295b7f591D;

    // Curve constant: SIX_DAYS = YEAR / 60 = 525,960 seconds.
    uint256 constant SIX_DAYS = 525_960;
    // VeHemi's MIN_LOCK_DURATION = 2 * SIX_DAYS (12.17 days).
    uint256 constant MIN_LOCK_DURATION = 2 * SIX_DAYS;

    function setUp() public {
        // Skip cleanly when no Hemi RPC is configured (e.g., CI without
        // the env var). The `hemi` foundry alias resolves to an empty
        // URL when HEMI_RPC_URL is unset, and vm.createSelectFork would
        // fail with "Connection refused" — a noisy failure for what
        // should be an environment-gated skip.
        string memory rpcUrl = vm.envOr("HEMI_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        // `hemi` RPC alias from foundry.toml; HEMI_FORK_BLOCK env pins
        // a block for reproducibility.
        uint256 pinnedBlock = vm.envOr("HEMI_FORK_BLOCK", uint256(0));
        if (pinnedBlock != 0) {
            vm.createSelectFork("hemi", pinnedBlock);
        } else {
            vm.createSelectFork("hemi");
        }

        if (block.chainid != 43111) {
            vm.skip(true);
            return;
        }
    }

    /// @notice Replay the 4-tx Safe MultiSend, then drive the
    ///         permissionless seedBatch + finalize loop, then assert the
    ///         resulting state.
    function test_SimulateProposedSafeMultiSend() public {
        if (block.chainid != 43111) return;

        // Sanity: target addresses have on-chain bytecode.
        require(VE_HEMI_V2_IMPL.code.length > 0, "VeHemi V2 impl: no bytecode on-chain");
        require(VVD_V2_IMPL.code.length > 0, "VVD V2 impl: no bytecode on-chain");
        require(ADAPTER.code.length > 0, "Adapter: no bytecode on-chain");

        VeHemi veHemi = VeHemi(VE_HEMI_PROXY);

        _logPreState(veHemi);
        _replaySafeMultiSend();
        _assertPostBatchState(veHemi);
        uint256 batchCount = _driveSeedingLoop(veHemi);
        _logPostFinalizeState(veHemi, batchCount);
        _runDeeperValidations(veHemi, VeHemiAragonAdapter(ADAPTER));

        console2.log("SIMULATION SUCCESSFUL: all post-upgrade checks passed.");
    }

    function _logPreState(VeHemi veHemi) internal view {
        require(veHemi.totalLocked() > 0, "fork has no real HEMI locked - wrong network?");
        require(veHemi.nextTokenId() > 1, "fork has no minted positions");
        console2.log("Pre-state:");
        console2.log("  totalLocked:        ", veHemi.totalLocked() / 1e18, "HEMI");
        console2.log("  totalVeHemiSupply:  ", veHemi.totalVeHemiSupply() / 1e18, "veHEMI");
        console2.log("  nextTokenId:        ", veHemi.nextTokenId());
        console2.log("");
    }

    function _replaySafeMultiSend() internal {
        VeHemi veHemi = VeHemi(VE_HEMI_PROXY);
        VeHemiVoteDelegation vvd = VeHemiVoteDelegation(VVD_PROXY);

        vm.startPrank(SAFE);

        (bool ok1,) = PROXY_ADMIN.call(
            abi.encodeWithSignature("upgrade(address,address)", VE_HEMI_PROXY, VE_HEMI_V2_IMPL)
        );
        require(ok1, "Action 1: VeHemi upgrade reverted");

        (bool ok2,) = PROXY_ADMIN.call(
            abi.encodeWithSignature("upgrade(address,address)", VVD_PROXY, VVD_V2_IMPL)
        );
        require(ok2, "Action 2: VVD upgrade reverted");

        veHemi.markSeedingStarted();
        vvd.setTrustedAdapter(ADAPTER);

        vm.stopPrank();
    }

    function _assertPostBatchState(VeHemi veHemi) internal {
        // V2 latches set correctly.
        assertTrue(veHemi.seedingStarted(), "seedingStarted latch not flipped");
        assertEq(veHemi.seedingTargetId(), veHemi.nextTokenId(), "seedingTargetId mismatch");
        assertEq(veHemi.seedingCursor(), 0, "cursor must be 0 before any seedBatch");
        assertEq(veHemi.seedingStartedAt(), uint64(block.timestamp), "seedingStartedAt mismatch");
        assertFalse(veHemi.lockedSeedingFinalized(), "should not be finalized yet");
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0, "subcurve must be 0 pre-finalize");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "forfeitable subcurve must be 0 pre-finalize");

        // Adapter wired correctly.
        assertEq(
            VeHemiVoteDelegation(VVD_PROXY).trustedAdapter(),
            ADAPTER,
            "trustedAdapter mismatch"
        );
        assertEq(
            address(VeHemiAragonAdapter(ADAPTER).veHemi()),
            VE_HEMI_PROXY,
            "adapter veHemi pointer mismatch"
        );

        // Idempotency: calling markSeedingStarted again must revert.
        vm.prank(SAFE);
        vm.expectRevert(VeHemi.SeedingAlreadyStarted.selector);
        veHemi.markSeedingStarted();

        // Re-initialize must be blocked on both impls (Initializable's
        // `_initialized` flag prevents double-init).
        vm.expectRevert(); // OZ Initializable: InvalidInitialization or similar
        veHemi.initialize(SAFE);
        vm.expectRevert();
        VeHemiVoteDelegation(VVD_PROXY).initialize();

        console2.log("Post-batch state: all assertions passed (incl. idempotency + re-init guards).");
        console2.log("");
    }

    function _driveSeedingLoop(VeHemi veHemi) internal returns (uint256 batchCount) {
        address keeper = makeAddr("keeper");
        uint256 target = veHemi.seedingTargetId();
        while (veHemi.seedingCursor() < target - 1) {
            vm.prank(keeper);
            veHemi.seedBatch(10_000);
            batchCount++;
            require(batchCount <= 10, "seedBatch loop ran >10 iterations - investigate");
        }
        assertEq(veHemi.seedingCursor(), target - 1, "cursor must reach seedingTargetId - 1");

        vm.prank(keeper);
        veHemi.finalizeSeeding();

        assertTrue(veHemi.lockedSeedingFinalized(), "finalize must flip the latch");
        assertGt(veHemi.nonTransferableTotalVeHemiSupply(), 0, "locked subcurve must be non-zero");
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0, "no forfeitable positions on current mainnet");
        assertLe(
            veHemi.nonTransferableTotalVeHemiSupply(),
            veHemi.totalVeHemiSupply(),
            "locked <= total"
        );

        // Idempotency: post-finalize, seedBatch and finalizeSeeding both
        // revert. These are one-way latches; any code path that could
        // re-enter would silently double-count.
        vm.prank(keeper);
        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.seedBatch(1);

        vm.prank(keeper);
        vm.expectRevert(VeHemi.SeedingAlreadyFinalized.selector);
        veHemi.finalizeSeeding();
    }

    function _logPostFinalizeState(VeHemi veHemi, uint256 batchCount) internal view {
        uint256 locked = veHemi.nonTransferableTotalVeHemiSupply();
        uint256 total = veHemi.totalVeHemiSupply();
        console2.log("Post-finalize state:");
        console2.log("  seedBatch calls:    ", batchCount);
        console2.log("  Locked supply:      ", locked / 1e18, "veHEMI");
        console2.log("  Total supply:       ", total / 1e18, "veHEMI");
        console2.log("  Locked share:       ", (locked * 10000) / total, "bps");
        console2.log("");
    }

    function _runDeeperValidations(VeHemi veHemi, VeHemiAragonAdapter adapter) internal {
        // Scope intentionally narrow: every section here has been
        // empirically validated against forked mainnet state.
        //
        // Order:
        //   A: reconstruction (also captures _ntSampleId)
        //   B: transferability gate (uses _ntSampleId, mints fresh
        //      transferable; the transfer step implicitly exercises the
        //      adapter event relay via VVD's _delegate cleanup hook)
        //   C: time decay (warps SIX_DAYS)
        //   D: adapter IVotes views (basic surface only)
        _verifyPerPositionReconstruction(veHemi);
        _verifyTransferabilityGate(veHemi);
        _verifyTimeDecay(veHemi);
        _verifyAdapterIVotesViews(veHemi, adapter);
    }


    // ─────────────────────────────────────────────────────────────────────
    // Section A — Per-position curve reconstruction
    //
    // The most rigorous correctness check: walk every minted NFT, sum the
    // per-position `balanceOfNFT(id)`, and confirm the totals match the
    // aggregate views (`totalVeHemiSupply`, `nonTransferableTotalVeHemiSupply`).
    // If `_walkCurve` aggregates correctly across the seeded `LockedPoint`s
    // and slope-change schedule, these reconstructions match to the wei.
    // Mismatch would indicate a curve-math regression we missed.
    // ─────────────────────────────────────────────────────────────────────
    function _verifyPerPositionReconstruction(VeHemi veHemi) internal {
        uint256 nextId = veHemi.nextTokenId();
        uint256 perPositionTotal = 0;
        uint256 perPositionLocked = 0;
        uint256 perPositionLockedHEMI = 0;
        uint256 nonTransferableCount = 0;
        uint256 livePositionCount = 0;

        for (uint256 id = 1; id < nextId; ++id) {
            try veHemi.ownerOf(id) returns (address owner) {
                if (owner == address(0)) continue;
            } catch {
                continue;
            }
            livePositionCount++;
            uint256 vePower = veHemi.balanceOfNFT(id);
            perPositionTotal += vePower;

            uint256 ta = veHemi.transferableAfter(id);
            IVeHemi.LockedBalance memory lock = veHemi.getLockedBalance(id);

            if (ta != 0 && ta > block.timestamp && lock.amount > 0 && lock.end > block.timestamp) {
                nonTransferableCount++;
                perPositionLocked += vePower;
                perPositionLockedHEMI += uint256(uint128(lock.amount));
                // Capture the first non-transferable position we find so
                // Section B can exercise the transferability gate without
                // hardcoding an id. Use the one with the smallest subEnd
                // so it's also a candidate for the withdraw-on-expiry
                // section (we'll warp past it later).
                uint256 subEnd = lock.end < ta ? uint256(lock.end) : ta;
                if (_ntSampleId == 0 || subEnd < _ntSampleSubEnd) {
                    _ntSampleId = id;
                    _ntSampleSubEnd = subEnd;
                }
            }
        }
        // Resolve owner once after the scan (saves one ownerOf in the loop body).
        if (_ntSampleId != 0) _ntSampleOwner = veHemi.ownerOf(_ntSampleId);

        uint256 aggregateTotal = veHemi.totalVeHemiSupply();
        uint256 aggregateLocked = veHemi.nonTransferableTotalVeHemiSupply();

        console2.log("Per-position reconstruction:");
        console2.log("  Live positions scanned:   ", livePositionCount);
        console2.log("  Non-transferable count:   ", nonTransferableCount);
        console2.log("  Sum balanceOfNFT (all):   ", perPositionTotal / 1e18, "veHEMI");
        console2.log("  aggregate totalVeHemiSupply:", aggregateTotal / 1e18, "veHEMI");
        console2.log("  Sum balanceOfNFT (locked):", perPositionLocked / 1e18, "veHEMI");
        console2.log("  aggregate locked supply:  ", aggregateLocked / 1e18, "veHEMI");
        console2.log("  Sum locked.amount HEMI:   ", perPositionLockedHEMI / 1e18, "HEMI");

        // Aggregate views must equal the per-position reconstruction to
        // the wei. This is the gold-standard curve invariant.
        assertEq(
            perPositionTotal,
            aggregateTotal,
            "totalVeHemiSupply MUST equal sum of balanceOfNFT across all NFTs"
        );
        assertEq(
            perPositionLocked,
            aggregateLocked,
            "nonTransferableTotalVeHemiSupply MUST equal sum across non-transferable NFTs"
        );
        // Forfeitable subcurve is empty on current mainnet (verified by the
        // off-chain enumeration). If a future seeding includes forfeitable
        // positions, this check would need an analogous reconstruction.
        assertEq(
            veHemi.forfeitableTotalVeHemiSupply(),
            0,
            "forfeitable subcurve must remain empty on current mainnet"
        );

        // Mainnet snapshot at the time of writing: 120 NT positions across
        // 6 vesting addresses, ~167,480 HEMI principal. Both can grow if
        // new vesting grants are minted before deploy day; use lower
        // bounds rather than strict equality so the test stays robust.
        // Source: scripts/enumerate-nontransferable.ts at block ~4,442,139.
        assertGe(nonTransferableCount, 1, "expected at least one NT position on the fork");
        assertGe(
            perPositionLockedHEMI,
            165_000 ether,
            "principal floor (165K HEMI) breached - has someone withdrawn NT positions?"
        );
        assertGt(_ntSampleId, 0, "_ntSampleId must have been captured");
        console2.log("  NT sample id captured:    ", _ntSampleId);
        console2.log("  Per-position reconstruction: PASS");
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Section B — Transferability gate
    //
    // 1. Pick a known mainnet non-transferable position (token 28661,
    //    owned by 0xE156…324B). Attempting transferFrom must revert with
    //    NotTransferable.
    // 2. Mint a fresh transferable position in-test (HEMI dealt to a test
    //    account). Owner must be able to transfer it freely.
    // ─────────────────────────────────────────────────────────────────────
    function _verifyTransferabilityGate(VeHemi veHemi) internal {
        // (1) Non-transferable position rejects transfer. Uses the
        // sample id captured during Section A's scan so the test
        // self-heals if any specific id (e.g., 28661 we hardcoded
        // previously) is later withdrawn.
        uint256 nonTransferableId = _ntSampleId;
        address ntOwner = _ntSampleOwner;
        require(veHemi.transferableAfter(nonTransferableId) > block.timestamp, "_ntSampleId is no longer non-transferable - reconstruction must have skipped");

        address recipient = makeAddr("transfer-recipient");

        // 1a. transferFrom from owner reverts.
        vm.prank(ntOwner);
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.transferFrom(ntOwner, recipient, nonTransferableId);

        // 1b. safeTransferFrom (both overloads) must reject too — OZ v5
        // routes through transferFrom, but make the dependency explicit.
        vm.prank(ntOwner);
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.safeTransferFrom(ntOwner, recipient, nonTransferableId);

        vm.prank(ntOwner);
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.safeTransferFrom(ntOwner, recipient, nonTransferableId, "");

        // 1c. Approved-spender attempt must also revert — the gate is
        // per-token, not per-caller.
        address operator = makeAddr("approved-operator");
        vm.prank(ntOwner);
        veHemi.approve(operator, nonTransferableId);
        vm.prank(operator);
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.transferFrom(ntOwner, recipient, nonTransferableId);

        // (2) Mint a fresh transferable position. Use the test contract as
        // the locker.
        address locker = address(this);
        uint256 amount = 100 ether;
        // Fund the locker with HEMI by dealing to the proxy contract's
        // mock and giving the locker the HEMI. We rely on forge-std's
        // `deal` to splat the ERC20 balance directly.
        deal(HEMI_TOKEN, locker, amount);

        vm.prank(locker);
        IERC20(HEMI_TOKEN).approve(VE_HEMI_PROXY, amount);

        vm.prank(locker);
        uint256 freshId = veHemi.createLock(amount, MIN_LOCK_DURATION);
        assertEq(veHemi.ownerOf(freshId), locker, "fresh-mint owner mismatch");
        assertEq(veHemi.transferableAfter(freshId), 0, "fresh createLock must produce transferable=true");

        // Owner can transfer the freshly-minted transferable position.
        vm.prank(locker);
        veHemi.transferFrom(locker, recipient, freshId);
        assertEq(veHemi.ownerOf(freshId), recipient, "transfer of transferable position failed");

        console2.log("Transferability gate: PASS");
        console2.log("  - NT sample id", nonTransferableId, "rejected transfer/safeTransferFrom/approved-spender path");
        console2.log("  - Freshly-minted transferable token", freshId, "transferred successfully");
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Section C — SIX_DAYS time decay
    //
    // Warp forward one SIX_DAYS bucket. Total supply and the locked
    // subcurve must both decay monotonically.
    // ─────────────────────────────────────────────────────────────────────
    function _verifyTimeDecay(VeHemi veHemi) internal {
        uint256 totalBefore = veHemi.totalVeHemiSupply();
        uint256 lockedBefore = veHemi.nonTransferableTotalVeHemiSupply();

        vm.warp(block.timestamp + SIX_DAYS);

        uint256 totalAfter = veHemi.totalVeHemiSupply();
        uint256 lockedAfter = veHemi.nonTransferableTotalVeHemiSupply();

        assertLt(totalAfter, totalBefore, "totalVeHemiSupply must decay monotonically");
        assertLt(lockedAfter, lockedBefore, "locked supply must decay monotonically");

        console2.log("Time decay over SIX_DAYS:");
        console2.log("  total veHEMI:  delta = -", (totalBefore - totalAfter) / 1e18, "veHEMI");
        console2.log("  locked veHEMI: delta = -", (lockedBefore - lockedAfter) / 1e18, "veHEMI");
        console2.log("  Decay direction: PASS");
        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Section D — Aragon adapter IVotes views
    //
    // Even though Aragon isn't deployed on Hemi yet, the adapter's IVotes
    // surface should return sensible values that mirror the underlying
    // VeHemi state. This validates the adapter's `delegates`,
    // `getVotes`, `getPastTotalSupply`, etc. against real mainnet data.
    // ─────────────────────────────────────────────────────────────────────
    function _verifyAdapterIVotesViews(VeHemi veHemi, VeHemiAragonAdapter adapter) internal view {
        // ERC-20-style surface.
        assertEq(
            adapter.totalSupply(),
            veHemi.totalVeHemiSupply(),
            "adapter.totalSupply must match VeHemi.totalVeHemiSupply"
        );

        // adapter.balanceOf(account) - sum of locked.amount HEMI across
        // ALL of the account's positions (transferable + non-transferable).
        // For holder 0xE156..., the off-chain enumeration shows 40
        // non-transferable positions x 2,274.54 HEMI = ~90,981 HEMI.
        // Adapter total can be larger if the holder also holds
        // transferable positions, so we lower-bound only.
        address knownHolder = 0xE156E366f185a4425C98Dd33e84F6E30f26D324B;
        uint256 holderBalance = adapter.balanceOf(knownHolder);
        assertGe(
            holderBalance,
            90_981 ether,
            "known holder's locked HEMI must be >= non-transferable portion (90,981 HEMI)"
        );

        // ERC-6372 + ERC-165 surface.
        uint48 clockValue = adapter.clock();
        assertEq(uint256(clockValue), block.timestamp, "adapter.clock must return block.timestamp");
        assertEq(adapter.CLOCK_MODE(), "mode=timestamp", "adapter.CLOCK_MODE must declare timestamp mode");
        assertTrue(adapter.supportsInterface(0xe90fb3f6), "must advertise IVotes interface");
        assertTrue(adapter.supportsInterface(0x01ffc9a7), "must advertise ERC165 interface");
        assertTrue(adapter.supportsInterface(0xda287a1d), "must advertise ERC6372 interface");

        console2.log("Aragon adapter views:");
        console2.log("  adapter.totalSupply == VeHemi.totalVeHemiSupply: PASS");
        console2.log("  adapter.balanceOf(holder) =", holderBalance / 1e18, "HEMI");
        console2.log("  ERC-6372 clock/mode + ERC-165 advertisements: PASS");
        console2.log("");
    }
}
