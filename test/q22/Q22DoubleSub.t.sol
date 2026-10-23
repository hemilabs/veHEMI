// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {VeHemi} from "../../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../../src/VeHemiVoteDelegation.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice NO DOUBLE SUBTRACTION in a lock's final hour.
///
///   A retirement inside the window `imm < end <= H` (`imm =
///   block.timestamp + 1`, `H` the next hour boundary) decrements the
///   `expiredDelegations` SIX_DAYS bucket AND subtracts from the checkpoint
///   aggregate at `imm`. If the two ledgers disagreed about WHEN a
///   contribution left, the expiration sweep would take it a SECOND time and
///   `calculateExpiredDelegations` / `getPastVotes` would `panic 0x11`
///   permanently, on a public view and on the permissionless amortiser.
///
///   Every body drives the sweep hard: buckets shared by several positions,
///   buckets already partly drained, several delegatees, the
///   MAX_LOCK_DURATION wipe branch, a pending element written by the
///   permissionless amortiser, and flat (auto-relocking) weight mixed in. Each
///   asserts votes <= supply at every instant around the write and that the
///   views and the amortiser do not panic.
contract Q22DoubleSubTest is Test {
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal del;
    MockERC20 internal hemi;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");

    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant MONTH = YEAR / 12;
    uint256 internal constant SIX_DAYS = MONTH / 5;
    uint256 internal constant MAX_TIME = 4 * YEAR;
    uint256 internal constant AMT = 1_000_000e18;

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy p = new ERC1967Proxy(
            address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, owner)
        );
        veHemi = VeHemi(address(p));
        del = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(del);
        vm.warp(100 * SIX_DAYS + 1800);
    }

    // ------------------------------------------------------------- helpers
    function _mk(address who_, uint256 dur_, bool forfeitable_) internal returns (uint256 id) {
        hemi.mint(who_, AMT);
        vm.startPrank(who_);
        hemi.approve(address(veHemi), AMT);
        id = veHemi.createLockFor(AMT, dur_, who_, false, forfeitable_);
        vm.stopPrank();
    }

    function _mkTo(address who_, address delegatee_, uint256 dur_, bool forfeitable_)
        internal
        returns (uint256 id)
    {
        id = _mk(who_, dur_, forfeitable_);
        vm.prank(who_);
        del.delegate(id, delegatee_);
    }

    function _H(uint256 t) internal pure returns (uint256) {
        return (t / 1 hours) * 1 hours + 1 hours;
    }

    /// @dev Counts instants in `[from_, to_]` where the summed votes of `ds_`
    ///      exceed `getPastTotalSupply`. A `panic 0x11` in a read fails the
    ///      body.
    function _probe(address[] memory ds_, uint256 from_, uint256 to_, string memory tag)
        internal
        returns (uint256 violations, int256 worst)
    {
        for (uint256 t = from_; t <= to_; ++t) {
            uint256 sup = del.getPastTotalSupply(t);
            int256 sum;
            for (uint256 i; i < ds_.length; ++i) {
                sum += int256(del.getPastVotes(ds_[i], t));
            }
            int256 d = sum - int256(sup);
            if (d > 0) {
                violations++;
                if (d > worst) worst = d;
            }
        }
        emit log_named_uint(string.concat(tag, ": instants votes>supply"), violations);
        emit log_named_int(string.concat(tag, ": worst (wei)"), worst);
    }

    /// @dev Liveness of the two views the panic would brick, at `now`.
    function _liveness(address[] memory ds_, string memory tag) internal {
        for (uint256 i; i < ds_.length; ++i) {
            del.calculateExpiredDelegations(ds_[i]); // MUST NOT panic
            del.getVotes(ds_[i]); // MUST NOT panic
            try del.writeNewCheckpointForExpiredDelegations(ds_[i]) {
                emit log_named_string(string.concat(tag, ": amortiser wrote for"), vm.toString(ds_[i]));
            } catch (bytes memory err) {
                // NoExpirations() is the legitimate refusal. A panic is not.
                require(
                    err.length == 4 && bytes4(err) == VeHemiVoteDelegation.NoExpirations.selector,
                    "amortiser reverted with something other than NoExpirations"
                );
            }
            del.getVotes(ds_[i]);
        }
    }

    function _finalizeSeeding() internal {
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
    }

    function _one(address a_) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a_;
    }

    // ================================================================== D1
    /// @notice TWO positions share ONE bucket and ONE delegatee. One is
    ///         retired in the final minutes (the window); the other must still
    ///         be netted exactly once by the sweep.
    function test_Q22_D1_twoPositionsSameBucket_retireOneInFinalMinutes() public {
        uint256 idA = _mkTo(alice, carol, 2 * SIX_DAYS, false);
        uint256 idB = _mkTo(bob, carol, 2 * SIX_DAYS, false);
        uint256 end = veHemi.getLockedBalance(idA).end;
        assertEq(veHemi.getLockedBalance(idB).end, end, "fixture: same bucket");

        uint256 tau = end - 60;
        require(_H(tau) >= end, "fixture: not the deferral branch");
        vm.warp(tau);
        vm.prank(alice);
        veHemi.increaseUnlockTime(idA, 60 * SIX_DAYS);

        vm.warp(_H(tau) + 2 hours);
        _liveness(_one(carol), "D1");
        (uint256 v, ) = _probe(_one(carol), tau - 2, _H(tau) + 1, "D1");
        assertEq(v, 0, "D1: votes exceeded supply");
        idB;
    }

    // ================================================================== D2
    /// @notice THREE positions, one bucket, TWO retired in the final minutes,
    ///         back to back in the same second.
    function test_Q22_D2_threeInOneBucket_retireTwo() public {
        uint256 idA = _mkTo(alice, carol, 2 * SIX_DAYS, false);
        uint256 idB = _mkTo(bob, carol, 2 * SIX_DAYS, false);
        uint256 idC = _mkTo(dave, carol, 2 * SIX_DAYS, false);
        uint256 end = veHemi.getLockedBalance(idA).end;

        uint256 tau = end - 60;
        require(_H(tau) >= end, "fixture: not the deferral branch");
        vm.warp(tau);
        vm.prank(alice);
        veHemi.increaseUnlockTime(idA, 60 * SIX_DAYS);
        vm.prank(bob);
        veHemi.increaseUnlockTime(idB, 60 * SIX_DAYS);

        vm.warp(_H(tau) + 2 hours);
        _liveness(_one(carol), "D2");
        (uint256 v, ) = _probe(_one(carol), tau - 2, _H(tau) + 1, "D2");
        assertEq(v, 0, "D2: votes exceeded supply");
        idC;
    }

    // ================================================================== D3
    /// @notice The bucket is ALREADY PARTLY DRAINED by an ordinary mid-life
    ///         retirement before the final-minute one arrives.
    function test_Q22_D3_bucketPartlyDrained_thenFinalMinute() public {
        uint256 idA = _mkTo(alice, carol, 2 * SIX_DAYS, false);
        uint256 idB = _mkTo(bob, carol, 2 * SIX_DAYS, false);
        uint256 idC = _mkTo(dave, carol, 2 * SIX_DAYS, false);
        uint256 end = veHemi.getLockedBalance(idA).end;

        // mid-life: the ordinary branch, bucket decremented immediately
        vm.warp(end - SIX_DAYS);
        vm.prank(dave);
        veHemi.increaseUnlockTime(idC, 60 * SIX_DAYS);

        uint256 tau = end - 60;
        require(_H(tau) >= end, "fixture: not the deferral branch");
        vm.warp(tau);
        vm.prank(alice);
        veHemi.increaseUnlockTime(idA, 60 * SIX_DAYS);

        vm.warp(_H(tau) + 2 hours);
        _liveness(_one(carol), "D3");
        (uint256 v, ) = _probe(_one(carol), tau - 2, _H(tau) + 1, "D3");
        assertEq(v, 0, "D3: votes exceeded supply");
        idB;
    }

    // ================================================================== D4
    /// @notice A PENDING element written by the PERMISSIONLESS AMORTISER at
    ///         `H >= end` already netted the bucket; the final-minute
    ///         retirement (a forfeit at `end - 2`) then decrements the bucket
    ///         and subtracts at `imm`.
    function test_Q22_D4_amortiserPendingThenFinalMinuteRetire() public {
        veHemi.updateForfeitAdmin(owner);
        uint256 idA = _mkTo(alice, carol, 2 * SIX_DAYS, true);
        uint256 idB = _mkTo(bob, carol, 2 * SIX_DAYS, false);
        uint256 end = veHemi.getLockedBalance(idA).end;

        vm.warp(end - 2);
        require(_H(end - 2) >= end, "fixture: not the deferral branch");
        // pending element at H >= end, built by the amortiser
        del.writeNewCheckpointForExpiredDelegations(carol);
        uint256 votesPre = del.getVotes(carol);

        veHemi.forfeit(idA); // final-SECOND retirement, same hour as the pending

        assertEq(del.getVotes(carol), votesPre, "D4: retirement moved a value it must not");

        vm.warp(_H(end - 2) + 2 hours);
        _liveness(_one(carol), "D4");
        (uint256 v, ) = _probe(_one(carol), end - 4, _H(end - 2) + 1, "D4");
        assertEq(v, 0, "D4: votes exceeded supply");
        idB;
    }

    // ================================================================== D5
    /// @notice SEVERAL DELEGATEES, staggered ends, interleaved final-minute
    ///         retirements, and the amortiser run against each of them.
    function test_Q22_D5_severalDelegatees() public {
        uint256 idA = _mkTo(alice, carol, 2 * SIX_DAYS, false);
        uint256 idB = _mkTo(bob, dave, 3 * SIX_DAYS, false);
        uint256 idC = _mkTo(erin, carol, 3 * SIX_DAYS, false);

        uint256 endA = veHemi.getLockedBalance(idA).end;
        uint256 endB = veHemi.getLockedBalance(idB).end;

        address[] memory ds = new address[](2);
        ds[0] = carol;
        ds[1] = dave;

        uint256 tauA = endA - 60;
        require(_H(tauA) >= endA, "fixture A");
        vm.warp(tauA);
        vm.prank(alice);
        veHemi.increaseUnlockTime(idA, 60 * SIX_DAYS);
        _liveness(ds, "D5a");

        uint256 tauB = endB - 60;
        require(_H(tauB) >= endB, "fixture B");
        vm.warp(tauB);
        vm.prank(bob);
        veHemi.increaseUnlockTime(idB, 60 * SIX_DAYS);

        vm.warp(_H(tauB) + 2 hours);
        _liveness(ds, "D5b");
        (uint256 v, ) = _probe(ds, tauB - 2, _H(tauB) + 1, "D5");
        assertEq(v, 0, "D5: votes exceeded supply");
        idC;
    }

    // ================================================================== D6
    /// @notice The MAX_LOCK_DURATION WIPE BRANCH of `_calculateExpirations`.
    ///         A final-minute retirement is followed by a > 4 year gap before
    ///         the next checkpoint, so the wipe branch runs against an
    ///         aggregate whose bucket ledger the retirement has already
    ///         touched.
    function test_Q22_D6_maxLockWipeBranchAfterFinalMinuteRetire() public {
        uint256 idA = _mkTo(alice, carol, 2 * SIX_DAYS, false);
        uint256 idB = _mkTo(bob, carol, 2 * SIX_DAYS, false);
        uint256 end = veHemi.getLockedBalance(idA).end;

        uint256 tau = end - 60;
        require(_H(tau) >= end, "fixture: not the deferral branch");
        vm.warp(tau);
        vm.prank(alice);
        veHemi.increaseUnlockTime(idA, 60 * SIX_DAYS);

        // > MAX_LOCK_DURATION past the newest checkpoint -> the wipe branch
        vm.warp(tau + MAX_TIME + 10 days);
        _liveness(_one(carol), "D6");
        // a fresh booking into the wiped aggregate, then the views again
        uint256 idC = _mkTo(dave, carol, 2 * SIX_DAYS, false);
        _liveness(_one(carol), "D6b");
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        _liveness(_one(carol), "D6c");
        (uint256 v, ) = _probe(_one(carol), block.timestamp - 60, block.timestamp, "D6");
        assertEq(v, 0, "D6: votes exceeded supply");
        idB;
        idC;
    }

    // ================================================================== D7
    /// @notice FLAT (auto-relocking) weight shares the delegatee with the
    ///         decaying position retired in the final minutes. The flat term
    ///         owns no bucket, so the two ledgers must stay separable.
    function test_Q22_D7_flatWeightShares_theDelegatee() public {
        uint256 idFlat = _mkTo(alice, carol, 2 * SIX_DAYS, false);
        _finalizeSeeding();
        vm.prank(alice);
        veHemi.enableAutoRelock(idFlat);

        uint256 idB = _mkTo(bob, carol, 2 * SIX_DAYS, false);
        uint256 end = veHemi.getLockedBalance(idB).end;

        uint256 tau = end - 60;
        require(_H(tau) >= end, "fixture: not the deferral branch");
        vm.warp(tau);
        vm.prank(bob);
        veHemi.increaseUnlockTime(idB, 60 * SIX_DAYS);

        vm.warp(_H(tau) + 2 hours);
        _liveness(_one(carol), "D7");
        // and now retire the flat one
        vm.prank(alice);
        veHemi.disableAutoRelock(idFlat);
        _liveness(_one(carol), "D7b");
        (uint256 v, ) = _probe(_one(carol), tau - 2, _H(tau) + 1, "D7");
        assertEq(v, 0, "D7: votes exceeded supply");
    }

    // ================================================================== D8
    /// @notice A fresh `delegate()` CANNOT reach the window at all:
    ///         `_getNormalizedLockedInfo` refuses `end <= checkPointTimestamp_`
    ///         (the HOUR BOUNDARY) with `CanNotDelegateExpiredLocks`. So the
    ///         window is entered only by a leg whose NEW side is already beyond
    ///         `H`: `increaseUnlockTime`. This body pins the refusal and then
    ///         drives a redelegation in the SAME second as the retirement.
    function test_Q22_D8_delegateIsRefused_thenRedelegateInSameSecond() public {
        uint256 idA = _mkTo(alice, carol, 2 * SIX_DAYS, false);
        uint256 idB = _mkTo(bob, carol, 2 * SIX_DAYS, false);
        uint256 end = veHemi.getLockedBalance(idA).end;

        address[] memory ds = new address[](2);
        ds[0] = carol;
        ds[1] = dave;

        uint256 tau = end - 60;
        require(_H(tau) >= end, "fixture: not the deferral branch");
        vm.warp(tau);

        // (i) a plain redelegation in the window is REFUSED
        vm.prank(alice);
        vm.expectRevert(VeHemiVoteDelegation.CanNotDelegateExpiredLocks.selector);
        del.delegate(idA, dave);

        // (ii) the unprivileged route in: extend, which moves `end` past `H`
        vm.prank(alice);
        veHemi.increaseUnlockTime(idA, 60 * SIX_DAYS);
        // (iii) and immediately redelegate, in the SAME second, exercising the
        //       two-leg live/pending insert right after the in-window write
        vm.prank(alice);
        del.delegate(idA, dave);
        _liveness(ds, "D8a");

        vm.warp(_H(tau) + 2 hours);
        _liveness(ds, "D8b");
        (uint256 v, ) = _probe(ds, tau - 2, _H(tau) + 1, "D8");
        assertEq(v, 0, "D8: votes exceeded supply");
        idB;
    }

    // ================================================================== D9
    /// @notice Offsets spread across the final hour (`end - k`, k from 1 to
    ///         3599 on a doubling ladder): an `increaseUnlockTime` at each,
    ///         asserting votes <= supply around `tau` and around `end` and the
    ///         liveness of both views, so the body does not depend on which
    ///         second opens the branch.
    function test_Q22_D9_everySecondOfTheFinalHour() public {
        uint256 worstViolations;
        uint256 firstBadOffset;
        uint16[14] memory ks = [uint16(1), 2, 3, 5, 9, 17, 33, 65, 129, 257, 513, 1025, 2049, 3599];
        for (uint256 j; j < ks.length; ++j) {
            uint256 k = ks[j];
            uint256 snap = vm.snapshotState();
            uint256 idA = _mkTo(alice, carol, 2 * SIX_DAYS, false);
            uint256 idB = _mkTo(bob, carol, 2 * SIX_DAYS, false);
            uint256 end = veHemi.getLockedBalance(idA).end;
            uint256 tau = end - k;
            vm.warp(tau);
            vm.prank(alice);
            veHemi.increaseUnlockTime(idA, 60 * SIX_DAYS);
            vm.warp(_H(tau) + 2 hours);
            _liveness(_one(carol), "D9");
            (uint256 v, ) = _probe(_one(carol), tau - 1, tau + 1, "D9pt");
            (uint256 v2, ) = _probe(_one(carol), end - 2, end + 1, "D9end");
            v += v2;
            if (v > 0 && firstBadOffset == 0) firstBadOffset = k;
            worstViolations += v;
            idB;
            vm.revertToState(snap);
        }
        emit log_named_uint("D9: total instants votes>supply over the final hour", worstViolations);
        emit log_named_uint("D9: first offset (end - k) with a violation", firstBadOffset);
        assertEq(worstViolations, 0, "D9: votes exceeded supply somewhere in the final hour");
    }
}
