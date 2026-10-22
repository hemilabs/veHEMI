// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// TwinOracle -- test harness: THE MANUAL TWIN IS THE ORACLE.
// ----------------------------------------------------------------------------
// A "twin" is a REAL veHEMI position in a REAL VeHemi deployment that a
// simulated user extends by calling increaseUnlockTime() exactly once per
// SIX_DAYS bucket. Nothing is reconstructed or re-derived from the contract
// under test.
//
// Two independent UNIVERSES are deployed (each its own MockERC20 + VeHemi proxy
// + VeHemiVoteDelegation). vm.warp is global, so both universes see identical
// timestamps. Universe M holds the manual reference position; universe X holds
// the candidate (auto-relock) position. Because each universe contains only the
// positions the test puts in it, totalVeHemiSupply() / subcurve supplies /
// getPastTotalSupply() are directly comparable between universes.
//
// Inheritors implement `_driveCandidate(uint256 ts)` (or leave it empty), then
// use `spawn`/`step`/`sweep` and the closed forms `slopeOf`/`peakOf`/
// `meanLevelOf`, which call nothing in src.
// ============================================================================

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/VeHemiVoteDelegation.sol";
import "../src/interfaces/IVeHemi.sol";
import "../src/interfaces/IVeHemiVoteDelegation.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";

abstract contract TwinOracle is Test {
    // ---------------------------------------------------------------- constants
    uint256 internal constant YEAR = 365.25 days;          // 31_557_600
    uint256 internal constant SIX_DAYS = YEAR / (12 * 5);  //    525_960
    uint256 internal constant MAX_TIME = 4 * YEAR;         // 126_230_400
    uint256 internal constant BPS = 10_000;

    // ---------------------------------------------------------------- universes
    struct Stack {
        MockERC20 hemi;
        VeHemi ve;
        VeHemiVoteDelegation del;
    }

    Stack internal M; // manual reference universe
    Stack internal X; // candidate universe

    // ---------------------------------------------------------------- positions
    /// @dev How a driven position behaves at each bucket boundary.
    enum Cadence {
        MANUAL,        // extend every bucket boundary (THE ORACLE)
        NEVER,         // never extend (plain lock)
        STOPPED        // was manual, has been stopped (serve-out)
    }

    struct Pos {
        bool inX;          // false => universe M, true => universe X
        uint256 tokenId;
        address owner;     // also the delegatee (auto-delegate resolves to self)
        uint256 amount;
        uint256 N;         // requested bucket count; extension duration = N*SIX_DAYS
        Cadence cadence;
        uint256 extensionsAccepted;
        uint256 extensionsAttempted;
        bool withdrawn;
    }

    Pos[] internal positions;

    // ---------------------------------------------------------------- sampling
    struct Sample {
        uint256 ts;
        bool atBoundary;      // ts % SIX_DAYS == 0
        uint256 weight;       // balanceOfNFT(tokenId)
        uint256 votes;        // delegation.getVotes(owner)
        uint256 totalSupply;  // veHemi.totalVeHemiSupply()
        uint256 lockedSupply; // nonTransferableTotalVeHemiSupply()
        uint256 forfSupply;   // forfeitableTotalVeHemiSupply()
        uint256 lockEnd;      // getLockedBalance(tokenId).end
        int256 lockAmount;    // getLockedBalance(tokenId).amount
    }

    /// @dev series[posIndex] = chronological samples
    mapping(uint256 => Sample[]) internal series;

    uint256 internal t0; // bucket-aligned start timestamp

    // ============================================================ deployment

    function _deployStack() internal returns (Stack memory s) {
        s.hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(s.hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        s.ve = VeHemi(address(proxy));
        s.del = new VeHemiVoteDelegation(address(s.ve));
        s.ve.updateVoteDelegation(IVeHemiVoteDelegation(address(s.del)));
        // Flip the subcurve latch while the universe is empty so that
        // nonTransferable/forfeitable supplies are live for every position we
        // subsequently mint. With zero tokens the 3-phase flow is a no-op scan.
        s.ve.markSeedingStarted();
        s.ve.seedBatch(type(uint256).max);
        s.ve.finalizeSeeding();
    }

    /// @notice Deploy both universes and align the clock to a bucket boundary.
    function setUpTwinOracle() internal {
        // Start far enough in for binary searches to have history, and exactly
        // on a SIX_DAYS boundary so bucket arithmetic is unambiguous.
        vm.roll(1_000_000);
        vm.warp(2_000 * SIX_DAYS); // 1_051_920_000
        t0 = block.timestamp;
        require(t0 % SIX_DAYS == 0, "t0 not bucket aligned");
        M = _deployStack();
        X = _deployStack();
    }

    // ============================================================ position mint

    function spawn(
        bool inX,
        address owner,
        uint256 amount,
        uint256 N,
        Cadence cadence,
        bool nonTransferable,
        bool forfeitable
    ) internal returns (uint256 posIndex) {
        Stack memory s = inX ? X : M;
        s.hemi.mint(owner, amount);
        vm.startPrank(owner);
        s.hemi.approve(address(s.ve), type(uint256).max);
        uint256 id;
        if (nonTransferable) {
            id = s.ve.createLockFor(amount, N * SIX_DAYS, owner, false, forfeitable);
        } else {
            id = s.ve.createLock(amount, N * SIX_DAYS);
        }
        vm.stopPrank();

        posIndex = positions.length;
        positions.push(
            Pos({
                inX: inX,
                tokenId: id,
                owner: owner,
                amount: amount,
                N: N,
                cadence: cadence,
                extensionsAccepted: 0,
                extensionsAttempted: 0,
                withdrawn: false
            })
        );
    }

    /// @notice Convenience: mint the SAME position shape into both universes.
    ///         Returns (manualIndex, candidateIndex). The candidate starts as a
    ///         plain lock; the inheriting test drives it however it likes.
    function spawnPair(
        address ownerM,
        address ownerX,
        uint256 amount,
        uint256 N,
        Cadence candidateCadence
    ) internal returns (uint256 mi, uint256 xi) {
        mi = spawn(false, ownerM, amount, N, Cadence.MANUAL, false, false);
        xi = spawn(true, ownerX, amount, N, candidateCadence, false, false);
    }

    // ============================================================ driving

    /// @dev Override in a subclass to advance a design-specific position.
    ///      Called by `step()` at every boundary AND at every mid-bucket probe,
    ///      so implementations must be idempotent / no-op when nothing is due.
    function _driveCandidate(uint256 /*ts*/) internal virtual {}

    /// @dev Apply the built-in cadence rules to every registered position.
    function _driveBuiltIn(uint256 ts) internal {
        bool onBoundary = (ts % SIX_DAYS == 0);
        for (uint256 i; i < positions.length; ++i) {
            Pos storage p = positions[i];
            if (p.withdrawn) continue;
            Stack memory s = p.inX ? X : M;
            // NEVER / STOPPED are never due
            bool due = p.cadence == Cadence.MANUAL && onBoundary;
            if (!due) continue;
            p.extensionsAttempted++;
            vm.prank(p.owner);
            try s.ve.increaseUnlockTime(p.tokenId, p.N * SIX_DAYS) {
                p.extensionsAccepted++;
            } catch {}
        }
    }

    /// @notice Stop a position from extending further (clean serve-out).
    function stopExtending(uint256 posIndex) internal {
        positions[posIndex].cadence = Cadence.STOPPED;
    }

    // ============================================================ sampling

    function _sampleOne(uint256 i) internal view returns (Sample memory sm) {
        Pos storage p = positions[i];
        Stack memory s = p.inX ? X : M;
        sm.ts = block.timestamp;
        sm.atBoundary = (block.timestamp % SIX_DAYS == 0);
        sm.totalSupply = s.ve.totalVeHemiSupply();
        sm.lockedSupply = s.ve.nonTransferableTotalVeHemiSupply();
        sm.forfSupply = s.ve.forfeitableTotalVeHemiSupply();
        if (!p.withdrawn) {
            sm.weight = s.ve.balanceOfNFT(p.tokenId);
            IVeHemi.LockedBalance memory lb = s.ve.getLockedBalance(p.tokenId);
            sm.lockEnd = lb.end;
            sm.lockAmount = lb.amount;
        }
        sm.votes = s.del.getVotes(p.owner);
    }

    function _record() internal {
        for (uint256 i; i < positions.length; ++i) {
            series[i].push(_sampleOne(i));
        }
    }

    // ============================================================ time control

    /// @dev Advance to `ts`, drive everything due at `ts`, then record a sample.
    ///      Ordering at a boundary: warp -> drive -> record, so the recorded
    ///      boundary sample is POST-extension (the twin's peak).
    function step(uint256 ts) internal {
        require(ts >= block.timestamp, "backwards");
        if (ts > block.timestamp) {
            vm.roll(block.number + (ts - block.timestamp) / 12 + 1);
            vm.warp(ts);
        }
        _driveBuiltIn(ts);
        _driveCandidate(ts);
        _record();
    }

    /// @notice Walk `buckets` buckets forward. Every bucket is sampled at its
    ///         boundary, one hour in, and its last instant (the last one is
    ///         required for an exact trapezoid integral), plus
    ///         `probesPerBucket` evenly spaced instants inside it.
    function sweep(uint256 buckets, uint256 probesPerBucket) internal {
        require(block.timestamp % SIX_DAYS == 0, "sweep must start on a boundary");
        uint256 start = block.timestamp;
        for (uint256 b; b < buckets; ++b) {
            uint256 base = start + b * SIX_DAYS;
            step(base); // boundary, post-drive
            // Fixed probe one hour into the bucket: the hourly delegation
            // checkpoint boundary (CHECKPOINT_INTERVAL = 1 hours).
            step(base + 3600);
            for (uint256 k = 1; k <= probesPerBucket; ++k) {
                uint256 off = (SIX_DAYS * k) / (probesPerBucket + 1);
                if (off == 0 || off >= SIX_DAYS) continue;
                step(base + off);
            }
            step(base + SIX_DAYS - 1); // last instant before the next boundary
        }
    }

    // ============================================================ comparison

    function _bps(uint256 a, uint256 b) internal pure returns (int256) {
        if (b == 0) return a == 0 ? int256(0) : type(int256).max;
        return (int256(a) - int256(b)) * int256(BPS) / int256(b);
    }

    /// @dev Which scalar of a Sample to compare. Keeps the checker generic.
    enum Field { WEIGHT, VOTES, TOTAL_SUPPLY, LOCKED_SUPPLY, FORF_SUPPLY, LOCK_END, LOCK_AMOUNT }

    function _get(Sample memory s, Field f) internal pure returns (uint256) {
        if (f == Field.WEIGHT) return s.weight;
        if (f == Field.VOTES) return s.votes;
        if (f == Field.TOTAL_SUPPLY) return s.totalSupply;
        if (f == Field.LOCKED_SUPPLY) return s.lockedSupply;
        if (f == Field.FORF_SUPPLY) return s.forfSupply;
        if (f == Field.LOCK_END) return s.lockEnd;
        return uint256(s.lockAmount < 0 ? int256(0) : s.lockAmount);
    }

    /// @notice EXACT trapezoid integral of a field over the recorded series.
    ///         Exact whenever the underlying curve is linear between adjacent
    ///         samples.
    ///         Units: wei*seconds.
    function integral(uint256 i, Field f) internal view returns (uint256 acc) {
        Sample[] storage a = series[i];
        for (uint256 k = 1; k < a.length; ++k) {
            uint256 dt = a[k].ts - a[k - 1].ts;
            if (dt == 0) continue;
            uint256 v0 = _get(a[k - 1], f);
            uint256 v1 = _get(a[k], f);
            acc += ((v0 + v1) * dt) / 2;
        }
    }

    // ============================================================ analytics

    function slopeOf(uint256 amount) internal pure returns (uint256) {
        return uint256(int256(int128(int256(amount)) / int128(int256(MAX_TIME))));
    }

    function peakOf(uint256 amount, uint256 N) internal pure returns (uint256) {
        return slopeOf(amount) * N * SIX_DAYS;
    }

    /// @dev The unique flat level whose time-integral equals the twin's.
    function meanLevelOf(uint256 amount, uint256 N) internal pure returns (uint256) {
        return slopeOf(amount) * (2 * N - 1) * (SIX_DAYS / 2);
    }
}
