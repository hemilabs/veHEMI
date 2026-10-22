// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title D09NegativeControls -- the auto-relock ABI and log surface.
///
///   NC_A  the compiled auto-relock function surface is exactly the expected
///         ten (read from the compiled artifact), and rejected alternative
///         entry points are unanswerable on the deployed dispatcher.
///   NC_B  GUARD 8 (`SeedingNotFinalized`) holds on every door for a subcurve
///         position, is narrowed to `transferableAfter > block.timestamp`, and
///         only `enableAutoRelock` can create a term on an existing position.
///   NC_C  writers of `autoRelockRemaining` that emit no auto-relock event
///         (`increaseUnlockTime`, `forfeit`, `withdraw`) on the log stream.
///   NC_P  every auto-relock event payload agrees with storage.
///
/// The negative controls are PERMUTATIONS OR RESTRICTIONS OF THE RECORDED LOG
/// STREAM (or probes of the compiled artifact), so no modified copy of
/// `src/VeHemi.sol` is needed -- the same device `test/d09/D09Gate.t.sol` uses.
/// The flat level is V-MEAN, `slope * (R - SIX_DAYS/2)`.
///
/// Scope: the ABI and log surface -- what an indexer can derive from a
/// transaction's logs, and what the compiled dispatcher answers. Nothing below
/// moves a balance, a weight or a vote.

/// @notice The reference OFF-CHAIN INDEXER for the WRITER scope. It holds no
///         reference to `VeHemi`: every byte of its state comes from a decoded
///         log plus that log's block timestamp. Two switches, because what
///         is asserted is WHICH SWITCH A CORRECT INDEXER NEEDS:
///
///           deriveRFromEnd  R is re-derived from the `Checkpoint` payload
///                           (`R == newLock.end - grid(t)` while flat) instead
///                           of being taken once from `AutoRelockEnabled`.
///           handleBurn      an ERC-721 `Transfer(_, 0, id)` retires the
///                           position.
///
///         With both OFF it is the naive indexer: R comes from the flag
///         payload and nothing else. That indexer is the CONTROL, not the claim.
contract D09WriterStreamIndexer {
    uint256 internal constant MAX_TIME = 4 * 365.25 days;
    uint256 internal constant SIX_DAYS = (4 * 365.25 days) / 4 / 12 / 5;
    bytes32 internal constant TRANSFER =
        keccak256("Transfer(address,address,uint256)");

    uint256 public immutable token;
    bool public immutable deriveRFromEnd;
    bool public immutable handleBurn;

    uint64 public remaining; // R as this indexer believes it
    bool public flat; // learned from the flag events only
    int128 public bias;
    int128 public slope;
    uint64 public ts;
    bool public exists;
    bool public retired;

    uint256 public checkpointsApplied;
    uint256 public flagEventsApplied;
    uint256 public burnsApplied;

    constructor(uint256 tokenId_, bool deriveRFromEnd_, bool handleBurn_) {
        token = tokenId_;
        deriveRFromEnd = deriveRFromEnd_;
        handleBurn = handleBurn_;
    }

    /// @param logs_ one transaction's logs, IN STREAM ORDER
    /// @param t_    that transaction's block timestamp
    function feed(Vm.Log[] memory logs_, uint64 t_) external {
        for (uint256 i; i < logs_.length; ++i) {
            bytes32 _t0 = logs_[i].topics[0];
            if (_t0 == IVeHemi.AutoRelockEnabled.selector) {
                if (uint256(logs_[i].topics[1]) != token) continue;
                remaining = abi.decode(logs_[i].data, (uint64));
                flat = true;
                flagEventsApplied += 1;
            } else if (_t0 == IVeHemi.AutoRelockDisabled.selector) {
                if (uint256(logs_[i].topics[1]) != token) continue;
                remaining = 0;
                flat = false;
                flagEventsApplied += 1;
            } else if (_t0 == IVeHemi.Checkpoint.selector) {
                (, uint256 _id, , IVeHemi.LockedBalance memory _new) = abi.decode(
                    logs_[i].data,
                    (uint256, uint256, IVeHemi.LockedBalance, IVeHemi.LockedBalance)
                );
                if (_id != token) continue;
                _applyPoint(_new, t_);
                checkpointsApplied += 1;
            } else if (handleBurn && _t0 == TRANSFER) {
                // ERC-721 puts all three fields in topics; the ERC-20 Transfer
                // of the released HEMI shares topic0 and has only two. The
                // arity IS the discriminator.
                if (logs_[i].topics.length != 4) continue;
                if (uint256(logs_[i].topics[3]) != token) continue;
                if (uint256(logs_[i].topics[2]) != 0) continue;
                (bias, slope, flat, remaining, retired) = (0, 0, false, 0, true);
                burnsApplied += 1;
            }
        }
    }

    /// @dev The branch structure of `src/lib/VeHemiCurveLib.sol::checkpoint`'s
    ///      Phase A and nothing else. The flat level is V-MEAN.
    function _applyPoint(IVeHemi.LockedBalance memory new_, uint64 t_) internal {
        if (retired) return;
        if (deriveRFromEnd && flat && new_.amount > 0 && new_.end > _grid(t_)) {
            // THE ONE LINE THE `increaseUnlockTime` WRITER NEEDS. While the
            // position is flat the stored end IS `grid(now) + R`, so the
            // Checkpoint payload republishes R on every writer -- including
            // the two that emit no auto-relock event at all.
            remaining = uint64(uint256(new_.end) - _grid(t_));
        }
        uint64 _r = flat ? remaining : 0;
        int128 _slope;
        int128 _bias;
        if (_r != 0 && new_.amount > 0) {
            _bias =
                (new_.amount / int128(int256(MAX_TIME))) *
                int128(int256(uint256(_r) - SIX_DAYS / 2));
        } else if (new_.end > t_ && new_.amount > 0) {
            _slope = new_.amount / int128(int256(MAX_TIME));
            _bias = _slope * int128(int256(uint256(new_.end) - uint256(t_)));
        }
        (bias, slope, ts, exists) = (_bias, _slope, t_, true);
    }

    function _grid(uint64 t_) internal pure returns (uint256) {
        return (uint256(t_) / SIX_DAYS) * SIX_DAYS;
    }

    /// @dev Mirrors the contract's own point evaluation.
    function balanceOf(uint64 t_) external view returns (uint256) {
        if (!exists || retired) return 0;
        int128 _b = bias - slope * int128(int256(uint256(t_) - uint256(ts)));
        return _b < 0 ? 0 : uint256(uint128(_b));
    }
}

contract D09NegativeControls is LockedCurveTestBase {
    uint256 internal constant AMT = 100 ether;
    uint256 internal constant DURATION = 2 * 365 days;
    address internal constant FADMIN = address(0xAD1);

    /// @dev Alternative auto-relock entry points that are NOT part of the
    ///      shipped surface. A build that answers any of these has a second door.
    string[4] internal REJECTED = [
        "setAutoRelock(uint256,bool)",
        "toggleAutoRelock(uint256)",
        "isLockLiveAt(uint256,uint256)",
        "effectiveUnlockTime(uint256)"
    ];

    /// @dev The shipped auto-relock function surface (ten functions, including
    ///      `createLockWithAutoRelock`, which mints and arms in one call, always
    ///      to `msg.sender`).
    function _convergedSurface() internal pure returns (string[10] memory) {
        return [
            "createLockWithAutoRelock(uint256,uint256,bool,bool)",
            "autoRelockRefreshedAt(uint256)",
            "autoRelockRemaining(uint256)",
            "autoRelockStaleAt(uint256)",
            "disableAutoRelock(uint256)",
            "effectiveLockEnd(uint256)",
            "enableAutoRelock(uint256)",
            "isAutoRelockEnabled(uint256)",
            "refreshAutoRelock(uint256)",
            "retireStaleAutoRelock(uint256)"
        ];
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _grid(uint256 t_) internal pure returns (uint256) {
        return (t_ / SIX_DAYS) * SIX_DAYS;
    }

    function _armed() internal returns (uint256 _id) {
        runSeedingFlow();
        (_id, , ) = createLock(alice, AMT, DURATION);
        // Deliberately OFF the SIX_DAYS grid.
        vm.warp(block.timestamp + 2 * SIX_DAYS + 3333);
    }

    /// @dev A NON-TRANSFERABLE position -- the only shape GUARD 8 is scoped
    ///      to, because it is the only shape enrolled in a subcurve.
    function _mintNonTransferable(address owner_, uint256 buckets_) internal returns (uint256 _id) {
        hemi.mint(owner_, AMT);
        vm.startPrank(owner_);
        hemi.approve(address(veHemi), type(uint256).max);
        _id = veHemi.createLockFor(AMT, buckets_ * SIX_DAYS, owner_, false, false);
        vm.stopPrank();
    }

    function _mintForfeitable(address owner_, uint256 buckets_) internal returns (uint256 _id) {
        hemi.mint(owner_, AMT);
        vm.startPrank(owner_);
        hemi.approve(address(veHemi), type(uint256).max);
        _id = veHemi.createLockFor(AMT, buckets_ * SIX_DAYS, owner_, false, true);
        vm.stopPrank();
    }

    function _has(string[] memory hay_, string memory needle_) internal pure returns (bool) {
        bytes32 _n = keccak256(bytes(needle_));
        for (uint256 i; i < hay_.length; ++i) {
            if (keccak256(bytes(hay_[i])) == _n) return true;
        }
        return false;
    }

    function _isAutoRelockRelated(string memory sig_) internal pure returns (bool) {
        if (keccak256(bytes(sig_)) == keccak256("effectiveLockEnd(uint256)")) return true;
        bytes memory _b = bytes(sig_);
        bytes memory _m = bytes("utoRelock");
        if (_b.length < _m.length) return false;
        for (uint256 i; i + _m.length <= _b.length; ++i) {
            bool _ok = true;
            for (uint256 j; j < _m.length; ++j) {
                if (_b[i + j] != _m[j]) {
                    _ok = false;
                    break;
                }
            }
            if (_ok) return true;
        }
        return false;
    }

    /// @dev The payload of the first log with this topic0 carrying this token.
    ///      Returns `found` separately so an absent log cannot read as a zero.
    function _payload(Vm.Log[] memory logs_, bytes32 topic0_, uint256 id_)
        internal
        pure
        returns (bool _found, bytes memory _data, bytes32[] memory _topics)
    {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] != topic0_) continue;
            if (logs_[i].topics.length < 2 || uint256(logs_[i].topics[1]) != id_) continue;
            return (true, logs_[i].data, logs_[i].topics);
        }
    }

    /// @dev How many ERC-721 burns of `id_` this stream carries. ERC-721 puts
    ///      all three fields in topics; the ERC-20 `Transfer` of the released
    ///      HEMI shares topic0 and has only two. The arity IS the discriminator.
    function _burns(Vm.Log[] memory logs_, uint256 id_) internal pure returns (uint256 _n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] != keccak256("Transfer(address,address,uint256)")) continue;
            if (logs_[i].topics.length != 4) continue;
            if (uint256(logs_[i].topics[3]) != id_) continue;
            if (uint256(logs_[i].topics[2]) != 0) continue;
            _n += 1;
        }
    }

    function _hasZeroedCheckpoint(Vm.Log[] memory logs_, uint256 id_) internal pure returns (bool) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] != IVeHemi.Checkpoint.selector) continue;
            (, uint256 _tid, , IVeHemi.LockedBalance memory _new) = abi.decode(
                logs_[i].data,
                (uint256, uint256, IVeHemi.LockedBalance, IVeHemi.LockedBalance)
            );
            if (_tid != id_) continue;
            if (_new.amount == 0 && _new.end == 0) return true;
        }
        return false;
    }

    /// @dev A stream RESTRICTION: the same logs with every `Checkpoint`
    ///      removed. The negative-control device of NC_C4.
    function _withoutCheckpoints(Vm.Log[] memory logs_) internal pure returns (Vm.Log[] memory _out) {
        uint256 _k;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] != IVeHemi.Checkpoint.selector) _k += 1;
        }
        _out = new Vm.Log[](_k);
        _k = 0;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] != IVeHemi.Checkpoint.selector) _out[_k++] = logs_[i];
        }
    }

    // ==================================================================
    // NC_A -- SINGLE ENTRY POINT, checked on the COMPILED ARTIFACT and on the
    //         DEPLOYED DISPATCHER.
    //
    // A faithful forwarder to the shipped entry point is behaviourally
    // invisible: every functional test asserts what the entry point DOES, and
    // the forwarder does exactly that. Only a SURFACE check sees a second door.
    // ==================================================================

    /// @notice NC_A1. The compiled auto-relock FUNCTION surface is EXACTLY the
    ///         expected ten -- in both directions.
    /// @dev    Reads `out/VeHemi.sol/VeHemi.json`, which `foundry.toml`'s
    ///         `fs_permissions` already grants and which
    ///         `test/StorageLayoutCompiledParity.t.sol` already reads.
    ///         BOUND, stated: `methodIdentifiers` carries FUNCTIONS only. The
    ///         event and error surface is not covered by this body.
    function test_D09_NC_A1_autoRelockFunctionSurfaceIsExactlyTheConvergedTen() public view {
        string memory _json = vm.readFile("out/VeHemi.sol/VeHemi.json");
        string[] memory _all = vm.parseJsonKeys(_json, ".methodIdentifiers");
        // Anti-vacuity: a filter that matched nothing, or an artifact that did
        // not parse, must not read as agreement.
        assertGt(_all.length, 50, "vacuity: the artifact's method table did not parse");

        string[] memory _got = new string[](_all.length);
        uint256 _n;
        for (uint256 i; i < _all.length; ++i) {
            if (_isAutoRelockRelated(_all[i])) _got[_n++] = _all[i];
        }
        assembly {
            mstore(_got, _n)
        }

        string[10] memory _want = _convergedSurface();
        for (uint256 i; i < 10; ++i) {
            assertTrue(
                _has(_got, _want[i]),
                string.concat("D09 ABI: the converged surface is MISSING ", _want[i])
            );
        }
        for (uint256 i; i < _n; ++i) {
            bool _expected;
            for (uint256 j; j < 10; ++j) {
                if (keccak256(bytes(_got[i])) == keccak256(bytes(_want[j]))) _expected = true;
            }
            assertTrue(
                _expected,
                string.concat("D09 ABI: UNEXPECTED auto-relock entry point ", _got[i])
            );
        }
        assertEq(_n, 10, "D09 ABI: the auto-relock function surface changed size");
    }

    /// @notice NC_A2. The rejected entry points, probed against the DEPLOYED
    ///         dispatcher. A rejected entry point is "answerable" if calling it
    ///         does anything other than miss the dispatcher.
    function test_D09_NC_A2_rejectedEntryPointsAreUnanswerable() public {
        uint256 _id = _armed();
        for (uint256 i; i < REJECTED.length; ++i) {
            bytes4 _sel = bytes4(keccak256(bytes(REJECTED[i])));
            vm.prank(alice);
            (bool _ok, bytes memory _ret) =
                address(veHemi).call(abi.encodeWithSelector(_sel, _id, uint256(1)));
            assertFalse(
                _ok,
                string.concat("D09: a REJECTED auto-relock entry point answered: ", REJECTED[i])
            );
            assertEq(
                _ret.length,
                0,
                string.concat("D09: a REJECTED entry point returned data -- it is implemented: ", REJECTED[i])
            );
        }
        // Anti-vacuity: the same probe against a CONVERGED selector must NOT
        // look like a dispatcher miss, or the instrument proves nothing.
        vm.prank(alice);
        (bool _ok2, ) = address(veHemi).call(
            abi.encodeWithSelector(bytes4(keccak256("isAutoRelockEnabled(uint256)")), _id)
        );
        assertTrue(_ok2, "vacuity: the probe cannot tell an implemented selector from a missing one");
    }

    // ==================================================================
    // NC_B -- WHY ONE ENTRY POINT.  GUARD 8 through every door.
    // ==================================================================

    /// @notice NC_B1. GUARD 8 refuses `enableAutoRelock` on the shape it is
    ///         scoped to -- a position enrolled in a subcurve -- and NO
    ///         rejected entry point offers a second way in.
    function test_D09_NC_B1_guard8HoldsOnEveryEntryPointForASubcurvePosition() public {
        // NO seeding flow: the latch is open.
        uint256 _id = _mintNonTransferable(alice, 40);
        assertGt(
            veHemi.transferableAfter(_id),
            block.timestamp,
            "vacuity: this position is not in GUARD 8's scope"
        );

        vm.prank(alice);
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        veHemi.enableAutoRelock(_id);

        for (uint256 i; i < REJECTED.length; ++i) {
            bytes4 _sel = bytes4(keccak256(bytes(REJECTED[i])));
            vm.prank(alice);
            (bool _ok, ) = address(veHemi).call(abi.encodeWithSelector(_sel, _id, uint256(1)));
            assertTrue(
                !_ok || veHemi.autoRelockRemaining(_id) == 0,
                string.concat("GUARD 8 BYPASSED through a second entry point: ", REJECTED[i])
            );
        }
        assertEq(veHemi.autoRelockRemaining(_id), 0, "GUARD 8: R was set before seeding finalized");
    }

    /// @notice NC_B2. GUARD 8 is NARROWED to positions with
    ///         `transferableAfter > block.timestamp`. A transferable-at-mint
    ///         position is never enrolled in a subcurve, so refusing it would
    ///         be feature-denial with nothing to protect, and the shipped
    ///         build ACCEPTS it. Asserted so that a silent RE-WIDENING is
    ///         visible.
    function test_D09_NC_B2_guard8IsNarrowedAndTheNarrowingIsTheShippedRule() public {
        uint256 _id;
        (_id, , ) = createLock(alice, AMT, DURATION);
        assertEq(veHemi.transferableAfter(_id), 0, "vacuity: this position is not transferable at mint");
        assertFalse(veHemi.lockedSeedingFinalized(), "vacuity: the seeding latch is already closed");

        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        assertGt(
            veHemi.autoRelockRemaining(_id),
            0,
            "GUARD 8 RE-WIDENED: a transferable-at-mint position is now refused before seeding"
        );
    }

    /// @notice NC_B3. WHY ONE ENTRY POINT IS THE WHOLE ARGUMENT: on an EXISTING
    ///         position a non-zero R can be CREATED by `enableAutoRelock` and by
    ///         nothing else (`createLockWithAutoRelock` creates one only on the
    ///         position it mints, always to `msg.sender`). Every other door on
    ///         the shipped surface, and every rejected one, is probed against
    ///         a position whose R is zero.
    function test_D09_NC_B3_onlyEnableCanCreateANonZeroTerm() public {
        uint256 _id = _armed();
        assertEq(veHemi.autoRelockRemaining(_id), 0, "vacuity: R is already set");

        vm.prank(alice);
        (bool _a, ) = address(veHemi).call(abi.encodeWithSelector(VeHemi.disableAutoRelock.selector, _id));
        vm.prank(alice);
        (bool _b, ) = address(veHemi).call(abi.encodeWithSelector(VeHemi.refreshAutoRelock.selector, _id));
        vm.prank(bob);
        (bool _c, ) = address(veHemi).call(abi.encodeWithSelector(VeHemi.retireStaleAutoRelock.selector, _id));
        vm.prank(alice);
        veHemi.increaseUnlockTime(_id, 3 * 365 days);
        assertTrue(!_a && !_b && !_c, "a non-enable door accepted the call on a term-free position");
        assertEq(veHemi.autoRelockRemaining(_id), 0, "a non-enable door CREATED a term");

        for (uint256 i; i < REJECTED.length; ++i) {
            bytes4 _sel = bytes4(keccak256(bytes(REJECTED[i])));
            vm.prank(alice);
            (bool _r, ) = address(veHemi).call(abi.encodeWithSelector(_sel, _id, uint256(1)));
            _r; // the return is not the claim here; the term is.
        }
        assertEq(veHemi.autoRelockRemaining(_id), 0, "a REJECTED door CREATED a term");

        // And the one door that can: the claim would be vacuous without it.
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        assertGt(veHemi.autoRelockRemaining(_id), 0, "vacuity: enableAutoRelock did not create a term either");
    }

    // ==================================================================
    // NC_C -- WRITERS OF THE TERM THAT EMIT NO AUTO-RELOCK EVENT.
    // ==================================================================

    /// @dev enable -> 3 buckets -> increaseUnlockTime -> 1 bucket. Returns
    ///      both transactions' log streams.
    function _extensionStreams()
        internal
        returns (uint256 _id, Vm.Log[] memory _l1, uint64 _t1, Vm.Log[] memory _l2, uint64 _t2)
    {
        _id = _armed();
        vm.recordLogs();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        _l1 = vm.getRecordedLogs();
        _t1 = uint64(block.timestamp);

        vm.warp(block.timestamp + 3 * SIX_DAYS);
        vm.recordLogs();
        vm.prank(alice);
        veHemi.increaseUnlockTime(_id, 3 * 365 days);
        _l2 = vm.getRecordedLogs();
        _t2 = uint64(block.timestamp);
    }

    /// @notice NC_C1. THE CLAIM. `increaseUnlockTime` writes R and emits NO
    ///         auto-relock event -- but it does emit the `Checkpoint`,
    ///         and while a position is flat the stored end IS `grid(now) + R`.
    ///         An indexer that re-derives R from that payload is EXACT across
    ///         the extension.
    function test_D09_NC_C1_endDerivedIndexerIsExactAcrossTheExtensionWriter() public {
        (uint256 _id, Vm.Log[] memory _l1, uint64 _t1, Vm.Log[] memory _l2, uint64 _t2) =
            _extensionStreams();

        D09WriterStreamIndexer _ix = new D09WriterStreamIndexer(_id, true, false);
        _ix.feed(_l1, _t1);
        _ix.feed(_l2, _t2);
        assertEq(_ix.checkpointsApplied(), 2, "vacuity: two checkpoints expected");
        assertEq(_ix.flagEventsApplied(), 1, "vacuity: exactly one flag event expected");

        // The indexer holds a term and it is the stored one. NC_C2 shows the
        // extension moved it (the flag-only indexer misses the move).
        assertGt(uint256(_ix.remaining()), 0, "vacuity: the indexer holds no term");
        assertEq(
            uint256(_ix.remaining()),
            uint256(veHemi.autoRelockRemaining(_id)),
            "the end-derived indexer lost the extension writer's term"
        );

        vm.warp(block.timestamp + 20 * SIX_DAYS);
        uint256 _truth = veHemi.balanceOfNFT(_id);
        uint256 _derived = _ix.balanceOf(uint64(block.timestamp));
        emit log_named_uint("truth    (flat, extended)", _truth);
        emit log_named_uint("stream-derived           ", _derived);
        assertGt(_truth, 0, "vacuity: the position carries no weight");
        assertEq(_derived, _truth, "the end-derived indexer must be EXACT across all four live writers");
    }

    /// @notice NC_C2. THE CONTROL. The naive indexer -- R taken from the flag
    ///         payload and from nothing else -- is WRONG after
    ///         `increaseUnlockTime`, and by how
    ///         much is reported. If the two ever agree this body fails, because
    ///         NC_C1 would then prove nothing about the extension writer.
    function test_D09_NC_C2_flagOnlyIndexerIsWrongAfterTheExtensionWriter() public {
        (uint256 _id, Vm.Log[] memory _l1, uint64 _t1, Vm.Log[] memory _l2, uint64 _t2) =
            _extensionStreams();

        D09WriterStreamIndexer _ix = new D09WriterStreamIndexer(_id, false, false);
        _ix.feed(_l1, _t1);
        _ix.feed(_l2, _t2);
        assertEq(_ix.flagEventsApplied(), 1, "vacuity: the flag-only indexer saw no flag event");

        vm.warp(block.timestamp + 20 * SIX_DAYS);
        uint256 _truth = veHemi.balanceOfNFT(_id);
        uint256 _derived = _ix.balanceOf(uint64(block.timestamp));
        emit log_named_uint("truth    (flat, extended)", _truth);
        emit log_named_uint("flag-only derived        ", _derived);
        assertGt(_truth, 0, "vacuity: the position carries no weight");
        assertLt(
            _derived,
            _truth,
            "the flag-only indexer must MISS the extension; if it does not, NC_C1 proves nothing"
        );
        uint256 _bps = ((_truth - _derived) * 10_000) / _truth;
        emit log_named_uint("under-report bps         ", _bps);
        assertGt(_bps, 0, "vacuity: the mis-derivation is below one basis point");
    }

    /// @dev enable a FORFEITABLE position, then forfeit it inside its window
    ///      with the term still live: the forfeit admin clears a LIVE R.
    function _forfeitStreams()
        internal
        returns (uint256 _id, Vm.Log[] memory _l1, uint64 _t1, Vm.Log[] memory _l2, uint64 _t2, uint256 _weightBefore)
    {
        runSeedingFlow();
        veHemi.updateForfeitAdmin(FADMIN);
        _id = _mintForfeitable(alice, 40);
        uint256 _ta = veHemi.transferableAfter(_id);
        vm.warp(block.timestamp + 999);

        vm.recordLogs();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        _l1 = vm.getRecordedLogs();
        _t1 = uint64(block.timestamp);

        vm.warp(_ta - 1);
        _weightBefore = veHemi.balanceOfNFT(_id);

        vm.recordLogs();
        vm.prank(FADMIN);
        veHemi.forfeit(_id);
        _l2 = vm.getRecordedLogs();
        _t2 = uint64(block.timestamp);
    }

    /// @notice NC_C3. `forfeit` clears a LIVE term without emitting
    ///         `AutoRelockDisabled` or `AutoRelockRetired` (as documented on
    ///         `IVeHemi::AutoRelockEnabled`). Two independent signals end the
    ///         position instead: the burn, and the `Checkpoint` whose `newLock`
    ///         is zeroed -- which retires it in any stream-ordered indexer, with
    ///         or without a burn handler.
    function test_D09_NC_C3_forfeitEmitsNoAutoRelockEventButTheCheckpointCarriesTheClear() public {
        (uint256 _id, Vm.Log[] memory _l1, uint64 _t1, Vm.Log[] memory _l2, uint64 _t2, uint256 _w) =
            _forfeitStreams();
        assertGt(_w, 0, "vacuity: the forfeited position carried no weight");

        // (a) No auto-relock event.
        (bool _fd, , ) = _payload(_l2, IVeHemi.AutoRelockDisabled.selector, _id);
        (bool _fr, , ) = _payload(_l2, IVeHemi.AutoRelockRetired.selector, _id);
        assertFalse(_fd, "forfeit now emits AutoRelockDisabled -- the shipped NatSpec says it does not");
        assertFalse(_fr, "forfeit now emits AutoRelockRetired -- the shipped NatSpec says it does not");
        assertEq(veHemi.autoRelockRemaining(_id), 0, "vacuity: forfeit did not clear the term");

        // (b) BOTH OTHER SIGNALS ARE PRESENT.
        assertEq(_burns(_l2, _id), 1, "the burn is not in the stream");
        assertTrue(_hasZeroedCheckpoint(_l2, _id), "the Checkpoint does not carry a zeroed newLock");

        // (c) AND THE INDEXER IS EXACT WITHOUT THE BURN HANDLER.
        D09WriterStreamIndexer _burnBlind = new D09WriterStreamIndexer(_id, true, false);
        _burnBlind.feed(_l1, _t1);
        _burnBlind.feed(_l2, _t2);
        assertEq(_burnBlind.burnsApplied(), 0, "vacuity: the burn handler was supposed to be off");
        assertEq(_burnBlind.balanceOf(_t2), 0, "the Checkpoint payload did not retire the position after all");

        D09WriterStreamIndexer _burnAware = new D09WriterStreamIndexer(_id, true, true);
        _burnAware.feed(_l1, _t1);
        _burnAware.feed(_l2, _t2);
        assertEq(_burnAware.burnsApplied(), 1, "vacuity: the burn-aware indexer saw no burn");
        assertEq(_burnAware.balanceOf(_t2), 0, "the burn-aware indexer still books weight for a burned position");
    }

    /// @notice NC_C4. THE CONTROL for NC_C3, and it is what turns "the
    ///         `Checkpoint` carries it" from an assertion into a measurement:
    ///         the SAME indexer, the SAME stream, with the `Checkpoint` logs
    ///         REMOVED (a stream RESTRICTION).
    ///         Deprived of that one payload the indexer books the flat weight
    ///         FOR EVER, because a flat position books no slope and nothing in
    ///         the auto-relock event set ever retires it.
    function test_D09_NC_C4_withoutTheCheckpointPayloadTheForfeitIsINVISIBLEFOREVER() public {
        (uint256 _id, Vm.Log[] memory _l1, uint64 _t1, Vm.Log[] memory _l2, uint64 _t2, uint256 _w) =
            _forfeitStreams();

        D09WriterStreamIndexer _ix = new D09WriterStreamIndexer(_id, true, false);
        _ix.feed(_l1, _t1);
        _ix.feed(_withoutCheckpoints(_l2), _t2);
        assertEq(_ix.checkpointsApplied(), 1, "vacuity: the restriction did not remove the forfeit checkpoint");

        uint256 _truth = veHemi.balanceOfNFT(_id);
        uint256 _derived = _ix.balanceOf(_t2);
        emit log_named_uint("weight before forfeit", _w);
        emit log_named_uint("truth  after forfeit ", _truth);
        emit log_named_uint("derived, no Checkpoint", _derived);
        assertEq(_truth, 0, "vacuity: the chain still books the forfeited position");
        assertGt(
            _derived,
            0,
            "removing the Checkpoint must break the reconstruction; if it does not, NC_C3 proves nothing"
        );

        // AND IT NEVER DECAYS: 400 buckets later it is still the same number.
        vm.warp(block.timestamp + 400 * SIX_DAYS);
        assertEq(
            _ix.balanceOf(uint64(block.timestamp)),
            _derived,
            "a flat position books no slope, so the error would be PERMANENT"
        );
    }

    /// @notice NC_C5. `withdraw` DOES write the term -- through
    ///         `_withdraw` -- but its own guard refuses a live term first, so
    ///         that write is reachable only at zero and an indexer has nothing
    ///         to miss. The guard is the reason, so the guard is what is
    ///         asserted.
    function test_D09_NC_C5_withdrawRefusesALiveTermSoItsWriteIsAlwaysANoOp() public {
        uint256 _id = _armed();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        vm.warp(block.timestamp + 200 * SIX_DAYS);

        // The FROZEN end is long past -- the position would be withdrawable on
        // the `end` test alone. Only the term guard stands between here and
        // full, never-decaying weight with no remaining lock-up.
        assertLt(
            uint256(veHemi.getLockedBalance(_id).end),
            block.timestamp,
            "vacuity: the frozen end has not gone stale, so the second guard could be doing the work"
        );
        assertGt(veHemi.balanceOfNFT(_id), 0, "vacuity: the position carries no weight");
        vm.prank(alice);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(_id);
        assertGt(veHemi.autoRelockRemaining(_id), 0, "withdraw cleared a live term");
    }

    // ==================================================================
    // NC_P -- THE EVENT PAYLOADS.
    // ==================================================================

    /// @notice NC_P1. `AutoRelockEnabled.remaining` agrees with the storage it
    ///         reports AND with the `Checkpoint` payload beside it.
    function test_D09_NC_P1_enabledPayloadAgreesWithStorageAndWithTheCheckpoint() public {
        uint256 _id = _armed();
        vm.recordLogs();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        Vm.Log[] memory _logs = vm.getRecordedLogs();

        (bool _found, bytes memory _data, ) = _payload(_logs, IVeHemi.AutoRelockEnabled.selector, _id);
        assertTrue(_found, "no AutoRelockEnabled log for this token at all");
        uint64 _r = abi.decode(_data, (uint64));
        assertGt(uint256(_r), 0, "AutoRelockEnabled published a zero term");
        assertEq(uint256(_r), uint256(veHemi.autoRelockRemaining(_id)), "AutoRelockEnabled.remaining != storage");
        assertEq(
            uint256(_r),
            uint256(veHemi.getLockedBalance(_id).end) - _grid(block.timestamp),
            "AutoRelockEnabled.remaining != end - grid(now), so the two publications disagree"
        );
    }

    /// @notice NC_P2. `AutoRelockDisabled.restoredEnd` is the end the position
    ///         actually lands on -- through BOTH doors that emit it, the
    ///         owner's `disableAutoRelock` and the permissionless
    ///         `retireStaleAutoRelock`.
    function test_D09_NC_P2_disabledPayloadIsTheRestoredEndThroughBothDoors() public {
        uint256 _id = _armed();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        vm.warp(block.timestamp + 10 * SIX_DAYS + 777);

        vm.recordLogs();
        vm.prank(alice);
        veHemi.disableAutoRelock(_id);
        (bool _f1, bytes memory _d1, ) =
            _payload(vm.getRecordedLogs(), IVeHemi.AutoRelockDisabled.selector, _id);
        assertTrue(_f1, "no AutoRelockDisabled log on the owner's door");
        uint64 _e1 = abi.decode(_d1, (uint64));
        assertGt(uint256(_e1), block.timestamp, "restoredEnd is not in the future");
        assertEq(uint256(_e1), uint256(veHemi.getLockedBalance(_id).end), "restoredEnd != the stored end (owner door)");
        assertEq(uint256(_e1), veHemi.effectiveLockEnd(_id), "restoredEnd != effectiveLockEnd (owner door)");

        // The permissionless door.
        uint256 _id2;
        (_id2, , ) = createLock(bob, AMT, DURATION);
        vm.prank(bob);
        veHemi.enableAutoRelock(_id2);
        vm.warp(veHemi.autoRelockStaleAt(_id2));
        vm.recordLogs();
        vm.prank(charlie);
        veHemi.retireStaleAutoRelock(_id2);
        (bool _f2, bytes memory _d2, ) =
            _payload(vm.getRecordedLogs(), IVeHemi.AutoRelockDisabled.selector, _id2);
        assertTrue(_f2, "no AutoRelockDisabled log on the permissionless door");
        uint64 _e2 = abi.decode(_d2, (uint64));
        assertEq(uint256(_e2), uint256(veHemi.getLockedBalance(_id2).end), "restoredEnd != the stored end (retire door)");
    }

    /// @notice NC_P3. `AutoRelockRefreshed.refreshedAt` is the ONLY published
    ///         input to the permissionless retirement window. The event alone
    ///         lets an indexer compute when `retireStaleAutoRelock` opens.
    function test_D09_NC_P3_refreshedPayloadDeterminesTheRetirementWindow() public {
        uint256 _id = _armed();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        vm.warp(block.timestamp + 7 * SIX_DAYS + 123);

        vm.recordLogs();
        vm.prank(alice);
        veHemi.refreshAutoRelock(_id);
        (bool _found, bytes memory _data, ) =
            _payload(vm.getRecordedLogs(), IVeHemi.AutoRelockRefreshed.selector, _id);
        assertTrue(_found, "no AutoRelockRefreshed log for this token at all");
        uint64 _at = abi.decode(_data, (uint64));
        assertEq(uint256(_at), block.timestamp, "AutoRelockRefreshed.refreshedAt is not this block");
        assertEq(uint256(_at), uint256(veHemi.autoRelockRefreshedAt(_id)), "refreshedAt != the stored stamp");
        assertEq(
            uint256(_at) + veHemi.STALE_FLAT_BUCKETS() * SIX_DAYS,
            veHemi.autoRelockStaleAt(_id),
            "the published stamp does not determine the retirement window"
        );

        // And the window it computes is the real one, at the boundary.
        vm.warp(uint256(_at) + veHemi.STALE_FLAT_BUCKETS() * SIX_DAYS - 1);
        vm.prank(charlie);
        vm.expectRevert(VeHemi.AutoRelockNotStale.selector);
        veHemi.retireStaleAutoRelock(_id);
        vm.warp(block.timestamp + 1);
        vm.prank(charlie);
        veHemi.retireStaleAutoRelock(_id);
        assertEq(veHemi.autoRelockRemaining(_id), 0, "vacuity: the retirement did not happen at the computed instant");
    }

    /// @notice NC_P4. `AutoRelockRetired.caller` names the party that acted,
    ///         and the point of the permissionless retirement is that it is
    ///         NOT the owner. The field is INDEXED, so it is `topics[2]`.
    function test_D09_NC_P4_retiredPayloadNamesThePermissionlessCaller() public {
        uint256 _id = _armed();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        vm.warp(veHemi.autoRelockStaleAt(_id));

        vm.recordLogs();
        vm.prank(charlie);
        veHemi.retireStaleAutoRelock(_id);
        (bool _found, , bytes32[] memory _topics) =
            _payload(vm.getRecordedLogs(), IVeHemi.AutoRelockRetired.selector, _id);
        assertTrue(_found, "no AutoRelockRetired log for this token at all");
        assertEq(_topics.length, 3, "AutoRelockRetired lost an indexed field");
        address _caller = address(uint160(uint256(_topics[2])));
        assertEq(_caller, charlie, "AutoRelockRetired.caller is not the party that acted");
        assertTrue(_caller != veHemi.ownerOf(_id), "vacuity: the retirer was the owner, so the field proves nothing");
    }
}
