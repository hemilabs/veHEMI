// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title E-ORDER on the auto-relock event stream.
///
/// The event-order rule documented on `IVeHemi::AutoRelockEnabled` (called
/// E-ORDER here): both flag events (`AutoRelockEnabled`, `AutoRelockDisabled`)
/// are emitted BEFORE the `Checkpoint` they describe, so a consumer that applies logs as they arrive
/// already knows the position is flat when the point lands.
///
/// The ordering is invisible to `vm.expectEmit` (which does not assert order
/// across different events) and to every state-reading test (contract state is
/// the same either way). Only a consumer that replays the LOG STREAM sees it:
///
///     E1 / E2   positional. The flag log index must be below the index of the
///               `Checkpoint` log for the same token.
///     OB / OC   a stream-ordered indexer, fed the real stream, reconstructs
///               `balanceOfNFT` exactly, buckets later, with no chain access.
///     OA / OD   controls. The same indexer, fed the same stream with the flag
///               logs moved after their checkpoint, is wrong -- so OB/OC cannot
///               pass merely because the indexer ignores the flag.
///
/// Scope: the ABI / log surface only. Emit order cannot move a balance, a
/// weight or a vote; the subject is what an indexer derives from the stream.

/// @notice The reference OFF-CHAIN INDEXER. It holds NO reference to
///         VeHemi: every byte of its state comes from a decoded log plus that
///         log's block timestamp, which is exactly what a subgraph has.
///         It applies each log THE INSTANT IT ARRIVES -- no transaction
///         buffering -- which is what a naive handler does and what E-ORDER
///         exists to make correct.
contract D09StreamIndexer {
    uint256 internal constant MAX_TIME = 4 * 365.25 days;
    uint256 internal constant SIX_DAYS = (4 * 365.25 days) / 4 / 12 / 5;

    uint256 public immutable token;

    uint64 public remaining; // R, learned from the flag events
    int128 public bias;
    int128 public slope;
    uint64 public ts;
    bool public exists;

    uint256 public checkpointsApplied;
    uint256 public flagEventsApplied;

    constructor(uint256 tokenId_) {
        token = tokenId_;
    }

    /// @param logs_ one transaction's logs, IN STREAM ORDER
    /// @param t_    that transaction's block timestamp
    function feed(Vm.Log[] memory logs_, uint64 t_) external {
        for (uint256 i; i < logs_.length; ++i) {
            bytes32 _t0 = logs_[i].topics[0];
            if (_t0 == IVeHemi.AutoRelockEnabled.selector) {
                if (uint256(logs_[i].topics[1]) != token) continue;
                remaining = abi.decode(logs_[i].data, (uint64));
                flagEventsApplied += 1;
            } else if (_t0 == IVeHemi.AutoRelockDisabled.selector) {
                if (uint256(logs_[i].topics[1]) != token) continue;
                remaining = 0;
                flagEventsApplied += 1;
            } else if (_t0 == IVeHemi.Checkpoint.selector) {
                (, uint256 _id, , IVeHemi.LockedBalance memory _new) = abi.decode(
                    logs_[i].data,
                    (uint256, uint256, IVeHemi.LockedBalance, IVeHemi.LockedBalance)
                );
                if (_id != token) continue;
                _applyPoint(_new, t_);
                checkpointsApplied += 1;
            }
        }
    }

    /// @dev The branch structure of the curve library's Phase A, and nothing
    ///      else. The flat level is the bucket mean:
    ///      `slope * (R - SIX_DAYS/2)`.
    function _applyPoint(IVeHemi.LockedBalance memory new_, uint64 t_) internal {
        uint64 _r = remaining;
        int128 _slope;
        int128 _bias;
        if (_r != 0 && new_.amount > 0) {
            // flat: stored slope stays 0, so the decay walk never touches it
            _bias =
                (new_.amount / int128(int256(MAX_TIME))) *
                int128(int256(uint256(_r) - SIX_DAYS / 2));
        } else if (new_.end > t_ && new_.amount > 0) {
            _slope = new_.amount / int128(int256(MAX_TIME));
            _bias = _slope * int128(int256(uint256(new_.end) - uint256(t_)));
        }
        (bias, slope, ts, exists) = (_bias, _slope, t_, true);
    }

    /// @dev Mirrors the contract's own point evaluation: bias - slope*(t - ts),
    ///      clamped at zero.
    function balanceOf(uint64 t_) external view returns (uint256) {
        if (!exists) return 0;
        int128 _b = bias - slope * int128(int256(uint256(t_) - uint256(ts)));
        return _b < 0 ? 0 : uint256(uint128(_b));
    }
}

contract D09Gate is LockedCurveTestBase {
    uint256 internal constant AMOUNT = 100 ether;
    uint256 internal constant DURATION = 2 * 365 days;

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _armedPosition() internal returns (uint256 _id) {
        // Seeding is finalized first. (The seeding guard refuses
        // `enableAutoRelock` only on a subcurve position; this one is
        // transferable.)
        runSeedingFlow();
        (_id, , ) = createLock(alice, AMOUNT, DURATION);
        // Deliberately OFF the SIX_DAYS grid: the reconstruction must not be
        // an accident of a round timestamp.
        vm.warp(block.timestamp + 2 * SIX_DAYS + 3333);
    }

    /// @dev index of the first log with this topic0 whose token is `id_`,
    ///      or type(uint256).max. Indexed tokenId lives in topics[1].
    function _flagIndex(Vm.Log[] memory logs_, bytes32 topic0_, uint256 id_) internal pure returns (uint256) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] == topic0_ && logs_[i].topics.length > 1 && uint256(logs_[i].topics[1]) == id_) {
                return i;
            }
        }
        return type(uint256).max;
    }

    /// @dev index of the single `Checkpoint` log carrying this token, plus how
    ///      many there were. `Checkpoint` has NO indexed fields, so the token
    ///      has to be decoded out of the data.
    function _checkpointIndex(Vm.Log[] memory logs_, uint256 id_)
        internal
        pure
        returns (uint256 _idx, uint256 _count)
    {
        _idx = type(uint256).max;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] != IVeHemi.Checkpoint.selector) continue;
            (, uint256 _tid, , ) = abi.decode(
                logs_[i].data,
                (uint256, uint256, IVeHemi.LockedBalance, IVeHemi.LockedBalance)
            );
            if (_tid != id_) continue;
            if (_count == 0) _idx = i;
            _count += 1;
        }
    }

    /// @dev The wrong order, applied to the STREAM rather than to the contract:
    ///      a stable partition that moves every auto-relock flag log to the end,
    ///      i.e. after the `Checkpoint` it describes. This is what makes the
    ///      controls controls without a modified copy of `src/VeHemi.sol`.
    function _flagTrailingStream(Vm.Log[] memory logs_) internal pure returns (Vm.Log[] memory _out) {
        _out = new Vm.Log[](logs_.length);
        uint256 _k;
        for (uint256 i; i < logs_.length; ++i) {
            if (!_isFlag(logs_[i].topics[0])) _out[_k++] = logs_[i];
        }
        for (uint256 i; i < logs_.length; ++i) {
            if (_isFlag(logs_[i].topics[0])) _out[_k++] = logs_[i];
        }
    }

    function _isFlag(bytes32 topic0_) internal pure returns (bool) {
        return topic0_ == IVeHemi.AutoRelockEnabled.selector || topic0_ == IVeHemi.AutoRelockDisabled.selector;
    }

    // ------------------------------------------------------------------
    // E1 / E2 -- THE POSITIONAL GATE.
    // ------------------------------------------------------------------

    function test_D09_gate4_E1_enableEmitsTheFlagBeforeItsCheckpoint() public {
        uint256 _id = _armedPosition();

        vm.recordLogs();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        Vm.Log[] memory _logs = vm.getRecordedLogs();

        uint256 _flag = _flagIndex(_logs, IVeHemi.AutoRelockEnabled.selector, _id);
        (uint256 _chk, uint256 _n) = _checkpointIndex(_logs, _id);

        assertTrue(_flag != type(uint256).max, "E-ORDER: no AutoRelockEnabled log for this token at all");
        assertEq(_n, 1, "E-ORDER: enable must publish exactly one Checkpoint for this token");
        assertLt(_flag, _chk, "E-ORDER VIOLATED: AutoRelockEnabled is emitted AFTER the Checkpoint it describes");
    }

    function test_D09_gate4_E2_disableEmitsTheFlagBeforeItsCheckpoint() public {
        uint256 _id = _armedPosition();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        vm.warp(block.timestamp + 10 * SIX_DAYS + 777);

        vm.recordLogs();
        vm.prank(alice);
        veHemi.disableAutoRelock(_id);
        Vm.Log[] memory _logs = vm.getRecordedLogs();

        uint256 _flag = _flagIndex(_logs, IVeHemi.AutoRelockDisabled.selector, _id);
        (uint256 _chk, uint256 _n) = _checkpointIndex(_logs, _id);

        assertTrue(_flag != type(uint256).max, "E-ORDER: no AutoRelockDisabled log for this token at all");
        assertEq(_n, 1, "E-ORDER: disable must publish exactly one Checkpoint for this token");
        assertLt(_flag, _chk, "E-ORDER VIOLATED: AutoRelockDisabled is emitted AFTER the Checkpoint it describes");
    }

    // ------------------------------------------------------------------
    // OB / OA -- THE ENABLE TRANSITION.
    // ------------------------------------------------------------------

    /// @notice O-B. The shipped order. The stream-ordered indexer is EXACT --
    ///         25 buckets later, with no transaction in between and no chain
    ///         access at all.
    function test_D09_OB_streamIndexerIsExactOnTheShippedOrder() public {
        uint256 _id = _armedPosition();

        vm.recordLogs();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        Vm.Log[] memory _logs = vm.getRecordedLogs();
        uint64 _t0 = uint64(block.timestamp);

        D09StreamIndexer _ix = new D09StreamIndexer(_id);
        _ix.feed(_logs, _t0);
        assertEq(_ix.checkpointsApplied(), 1, "vacuity: the indexer saw no checkpoint for this token");
        assertEq(_ix.flagEventsApplied(), 1, "vacuity: the indexer saw no flag event for this token");

        // Walk 25 buckets forward with no transaction at all. A correct
        // reconstruction is FLAT; a mis-derived one decays.
        vm.warp(block.timestamp + 25 * SIX_DAYS);
        uint64 _t1 = uint64(block.timestamp);
        uint256 _truth = veHemi.balanceOfNFT(_id);
        uint256 _derived = _ix.balanceOf(_t1);

        emit log_named_uint("truth   (flat)", _truth);
        emit log_named_uint("stream-derived", _derived);
        assertGt(_truth, 0, "vacuity: the position carries no weight");
        assertEq(_derived, _truth, "E-ORDER: the stream-ordered indexer must be EXACT on the shipped order");
    }

    /// @notice O-A. THE CONTROL. The SAME indexer, the same logs, with the flag
    ///         log moved after the `Checkpoint` -- and it is wrong. If this body
    ///         ever goes green by equality, O-B above is vacuous.
    function test_D09_OA_streamIndexerIsWrongWhenTheFlagTrailsTheCheckpoint() public {
        uint256 _id = _armedPosition();

        vm.recordLogs();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        Vm.Log[] memory _logs = vm.getRecordedLogs();
        uint64 _t0 = uint64(block.timestamp);

        D09StreamIndexer _ix = new D09StreamIndexer(_id);
        _ix.feed(_flagTrailingStream(_logs), _t0);

        vm.warp(block.timestamp + 25 * SIX_DAYS);
        uint64 _t1 = uint64(block.timestamp);
        uint256 _truth = veHemi.balanceOfNFT(_id);
        uint256 _derived = _ix.balanceOf(_t1);

        emit log_named_uint("truth   (flat)", _truth);
        emit log_named_uint("stream-derived", _derived);
        uint256 _bps = ((_truth - _derived) * 10_000) / _truth;
        emit log_named_uint("under-report bps", _bps);
        assertLt(_derived, _truth, "the flag-trailing stream must under-report; if it does not, O-B proves nothing");
        assertGt(_bps, 0, "vacuity: the mis-derivation is below one basis point");
    }

    // ------------------------------------------------------------------
    // OC / OD -- BOTH TRANSITIONS (the disable emit is the other half of
    // E-ORDER).
    // ------------------------------------------------------------------

    function _twoTransitionStreams()
        internal
        returns (uint256 _id, Vm.Log[] memory _l1, uint64 _t1, Vm.Log[] memory _l2, uint64 _t2)
    {
        _id = _armedPosition();

        vm.recordLogs();
        vm.prank(alice);
        veHemi.enableAutoRelock(_id);
        _l1 = vm.getRecordedLogs();
        _t1 = uint64(block.timestamp);

        vm.warp(block.timestamp + 10 * SIX_DAYS + 777);

        vm.recordLogs();
        vm.prank(alice);
        veHemi.disableAutoRelock(_id);
        _l2 = vm.getRecordedLogs();
        _t2 = uint64(block.timestamp);

        vm.warp(block.timestamp + 5 * SIX_DAYS);
    }

    /// @notice O-C. Enable, then disable, then five more buckets of pure decay.
    ///         The stream-ordered indexer is exact across BOTH transitions.
    function test_D09_OC_bothTransitionsAreExactInStreamOrder() public {
        (uint256 _id, Vm.Log[] memory _l1, uint64 _t1, Vm.Log[] memory _l2, uint64 _t2) = _twoTransitionStreams();

        D09StreamIndexer _ix = new D09StreamIndexer(_id);
        _ix.feed(_l1, _t1);
        _ix.feed(_l2, _t2);
        assertEq(_ix.checkpointsApplied(), 2, "vacuity: two checkpoints expected");
        assertEq(_ix.flagEventsApplied(), 2, "vacuity: two flag events expected");

        uint64 _t3 = uint64(block.timestamp);
        uint256 _truth = veHemi.balanceOfNFT(_id);
        uint256 _derived = _ix.balanceOf(_t3);

        emit log_named_uint("truth   (decaying again)", _truth);
        emit log_named_uint("stream-derived          ", _derived);
        assertGt(_truth, 0, "vacuity: the position carries no weight");
        assertEq(_derived, _truth, "E-ORDER: both transitions must reconstruct exactly in stream order");
    }

    /// @notice O-D. THE CONTROL for O-C. Both flag logs moved after their
    ///         checkpoints: the indexer now believes the position is still flat
    ///         at the old R and OVER-reports.
    function test_D09_OD_bothTransitionsAreWrongWhenTheFlagsTrail() public {
        (uint256 _id, Vm.Log[] memory _l1, uint64 _t1, Vm.Log[] memory _l2, uint64 _t2) = _twoTransitionStreams();

        D09StreamIndexer _ix = new D09StreamIndexer(_id);
        _ix.feed(_flagTrailingStream(_l1), _t1);
        _ix.feed(_flagTrailingStream(_l2), _t2);

        uint64 _t3 = uint64(block.timestamp);
        uint256 _truth = veHemi.balanceOfNFT(_id);
        uint256 _derived = _ix.balanceOf(_t3);

        emit log_named_uint("truth   (decaying again)", _truth);
        emit log_named_uint("stream-derived          ", _derived);
        uint256 _bps = ((_derived - _truth) * 10_000) / _truth;
        emit log_named_uint("over-report bps         ", _bps);
        assertGt(_derived, _truth, "the flag-trailing stream must over-report; if it does not, O-C proves nothing");
        assertGt(_bps, 0, "vacuity: the mis-derivation is below one basis point");
    }
}
