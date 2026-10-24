// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IVeHemi} from "src/interfaces/IVeHemi.sol";
import {IVeHemiVoteDelegation} from "src/interfaces/IVeHemiVoteDelegation.sol";

/**
 * @title AutoRelockLedgerHandler -- the auto-relock invariant handler and the
 *        ledger it keeps: each position's amount, end, transferableAfter,
 *        forfeitable flag and auto-relock term R, written from the calls the
 *        handler makes and never read back from the contract.
 * @notice Invariant handler for auto-relock, driven by `AutoRelockLedgerInvariantTest`
 *         (test/autorelock-ledger/AutoRelockLedgerInvariant.t.sol) and checked by `AutoRelockLedgerChecks`.
 *
 * @dev AUTHORED LEDGER. `Shadow` holds each position's amount, end,
 *      transferableAfter, forfeitable flag and R, written from the arguments
 *      this handler chose and its own clock using the documented rules, and
 *      never read back from the contract (a reconstruction from
 *      `getLockedBalance` moves together with a corrupted primitive). With
 *      `S = SIX_DAYS` and `grid(t) = floor(t / S) * S`:
 *        create   end = grid(now + duration)
 *        enable   R = floor((end - grid(now)) / S) * S, refused if R < 2 * S
 *        disable  end = grid(now) + R  (also keeper retire and armed transfer)
 *        top-up   end = grid(now) + R  while flat
 *        extend   R = unlockTime - grid(now)  while flat
 *        weight   flat ? slope * (R - S/2) : slope * (end - now)
 *        subcurve slope * (min(end, transferableAfter) - now) while now < transferableAfter
 *                 (flat or not)
 *
 *      MIRRORS AND PROBES. `fail_on_revert = true`, so an action mirrors the
 *      contract's preconditions and returns when one fails. A mirror stricter
 *      than the contract would silently never generate a path, so every call
 *      whose acceptance or refusal is itself the asserted property is issued
 *      by a probe action (`probe*`): the
 *      call runs under `try`, and the wrong outcome is counted as a
 *      violation (an acceptance of a call the contract must refuse, or, for
 *      `probeForfeitInWindowWhileFlat`, a refusal of a call it must accept).
 *      `increaseAmountByStranger` asserts its refusal directly.
 *
 *      Token selection starts at a fuzz-chosen offset (`_pick`, `_pickByFlatness`),
 *      so several actions land on the same position within a run.
 */
contract AutoRelockLedgerHandler is Test {
    VeHemi public veHemi;
    VeHemiVoteDelegation public delegation;
    MockERC20 public hemi;

    uint256 public constant YEAR = 365.25 days;
    uint256 public constant MONTH = YEAR / 12;
    uint256 public constant SIX_DAYS = MONTH / 5;
    uint256 public constant MAX_TIME = 4 * YEAR;
    /// @dev VeHemi.STALE_FLAT_BUCKETS, restated so a change to it is caught.
    uint256 public constant EXPECTED_STALE_FLAT_BUCKETS = 60;

    uint256 private constant MIN_AMOUNT = 11e18;
    uint256 private constant MAX_AMOUNT = 1_000e18;
    uint256 private constant MIN_DURATION = 2 * SIX_DAYS;
    uint256 private constant MAX_DURATION = 4 * YEAR;

    /// @dev Longest gap between checkpoints the supply views walk (255 buckets).
    uint256 public constant MAX_ACCUMULATED_WARP = SIX_DAYS * 255;
    uint256 public maxWarp = MAX_ACCUMULATED_WARP;

    address[5] public users;
    address public admin;
    bool public seeded;

    // ---------------------------------------------------------------------
    // Authored ledger
    // ---------------------------------------------------------------------
    struct Shadow {
        uint256 tokenId;
        bool alive;
        int128 amount;
        uint64 end;                 // the stored lock.end
        uint64 transferableAfter;   // 0 for a transferable lock
        bool forfeitable;
        uint64 autoRelockRemaining; // R, 0 when not flat
    }

    Shadow[] public shadows;

    function shadowsLength() external view returns (uint256) { return shadows.length; }

    /// @dev The refresh stamp (`autoRelockRefreshedAt`) authored by the last
    ///      enable or refresh, per token (0 once it leaves flat).
    mapping(uint256 => uint64) public authoredRefreshedAt;
    /// @dev Lifetime bounds, so a ledger total can be evaluated at a past
    ///      instant (`authoredTotalAt`).
    mapping(uint256 => uint64) public createdAt;
    mapping(uint256 => uint64) public burnedAt;

    /// @dev `(t, totalVeHemiSupplyAt(t), ledger total at t)` taken at `t = now`;
    ///      checked once `now` has moved past `t`. A later mutation in the same
    ///      second legitimately changes `totalVeHemiSupplyAt(t)` and clears
    ///      `valid`.
    struct PastSupplySample { uint256 timestamp; uint256 supply; uint256 authored; bool valid; }
    PastSupplySample[] public pastSupplySamples;
    function pastSupplySamplesLength() external view returns (uint256) { return pastSupplySamples.length; }

    // ---------------------------------------------------------------------
    // Coverage counters (fuzz-reached paths; see AutoRelockLedgerInvariantTest.afterInvariant)
    // ---------------------------------------------------------------------
    uint256 public enables;
    uint256 public disables;
    uint256 public staleRetires;
    uint256 public heartbeatRefreshes;
    uint256 public transferDisarms;
    uint256 public flatExtensions;
    uint256 public flatWithdrawProbes;
    uint256 public doubleEnableProbes;
    uint256 public shortREnableProbes;
    uint256 public disableNotEnabledProbes;
    uint256 public extendShorterProbes;
    uint256 public refreshStrangerProbes;
    uint256 public refreshNotEnabledProbes;
    uint256 public staleRetireEarlyProbes;
    uint256 public extendTooLongProbes;
    uint256 public forfeitOutOfWindowProbes;
    uint256 public forfeitInWindowFlatProbes;
    uint256 public bucketBoundaryCheckpoints;
    uint256 public bucketBoundaryEnables;
    uint256 public bucketBoundaryExactEndWithdraws;
    uint256 public bucketBoundaryExactEndTransfers;
    uint256 public expiredCheckpointWrites;
    uint256 public delegateRoutesChecked;

    // ---------------------------------------------------------------------
    // Violation counters (each must stay 0; asserted by AutoRelockLedgerChecks)
    // ---------------------------------------------------------------------
    uint256 public enableStepNotExact;
    uint256 public enableStepOverBucket;
    uint256 public maxEnableStepErrWei;
    uint256 public disableStepNotExact;
    uint256 public disableStepOverBucket;
    uint256 public maxDisableStepErrWei;
    uint256 public staleRetireStepNotExact;
    uint256 public maxStaleRetireStepErrWei;
    uint256 public extendWeightViolations;
    uint256 public maxExtendWeightErrWei;
    uint256 public abandonmentClockViolations;
    uint256 public delegationUpdateFailedCount;
    uint256 public transferDisarmMissed;
    uint256 public transferMisrouted;
    uint256 public delegateMisrouted;

    uint256 public flatWithdrawSuccesses;    // withdraw accepted on a flat position (withdraw, probeWithdrawWhileFlat)
    uint256 public flatWithdrawWeightLeaked; // largest weight that left that way
    uint256 public flatWithdrawWrongError;   // refused, but not with LockNotExpired
    uint256 public flatWithdrawAccepted;     // withdraw accepted on a flat position (probeFlatWithdrawBlocked)
    uint256 public doubleEnableAccepted;
    uint256 public shortREnableAccepted;
    uint256 public disableNotEnabledAccepted;
    uint256 public extendShorterAccepted;
    uint256 public refreshStrangerAccepted;
    uint256 public refreshNotEnabledAccepted;
    uint256 public staleRetireEarlyAccepted;
    uint256 public extendTooLongAccepted;
    uint256 public forfeitOutOfWindowAccepted;
    uint256 public forfeitInWindowFlatRefused;

    /// @notice Actor override for deterministic tests. While fuzzing it stays
    ///         `address(0)` and `msg.sender` (a `targetSender`) is the actor.
    address public actor;

    constructor(address admin_, address[5] memory users_) {
        users = users_;
        admin = admin_;
        hemi = new MockERC20("HEMI", "HEMI", 18);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new VeHemi(address(hemi))), abi.encodeWithSelector(VeHemi.initialize.selector, admin_)
        );
        veHemi = VeHemi(address(proxy));
        delegation = new VeHemiVoteDelegation(address(veHemi));
        vm.startPrank(admin_);
        veHemi.updateVoteDelegation(delegation);
        veHemi.updateForfeitAdmin(admin_);
        vm.stopPrank();
    }

    function setActorIdx(uint256 idx) public { actor = users[idx % users.length]; }
    function clearActor() public { actor = address(0); }
    function _sender() internal view returns (address) {
        return actor == address(0) ? msg.sender : actor;
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------
    function _ownerOfSafe(uint256 tokenId) internal view returns (address owner) {
        (bool ok, bytes memory data) = address(veHemi).staticcall(
            abi.encodeWithSignature("ownerOf(uint256)", tokenId)
        );
        if (!ok) return address(0);
        assembly { owner := mload(add(data, 32)) }
    }

    function _grid(uint256 t) internal pure returns (uint256) {
        return (t / SIX_DAYS) * SIX_DAYS;
    }

    /// @dev R at instant `t` for a position whose end is `end`.
    function _bucketR(uint256 end, uint256 t) internal pure returns (uint256) {
        uint256 g = _grid(t);
        if (end <= g) return 0;
        return ((end - g) / SIX_DAYS) * SIX_DAYS;
    }

    /// @dev Random scan start, so selection is not concentrated on token 1.
    function _pick(uint256 rand) internal view returns (int256) {
        uint256 n = shadows.length;
        if (n == 0) return -1;
        uint256 start = rand % n;
        for (uint256 k; k < n; ++k) {
            uint256 i = (start + k) % n;
            if (shadows[i].alive) return int256(i);
        }
        return -1;
    }

    /// @dev `_pick` restricted to flat (`wantFlat`) or non-flat positions, so
    ///      flat-only and unarmed-only actions do not no-op on a wrong draw.
    function _pickByFlatness(uint256 rand, bool wantFlat) internal view returns (int256) {
        uint256 n = shadows.length;
        if (n == 0) return -1;
        uint256 start = rand % n;
        for (uint256 k; k < n; ++k) {
            uint256 i = (start + k) % n;
            if (!shadows[i].alive) continue;
            if ((shadows[i].autoRelockRemaining != 0) != wantFlat) continue;
            return int256(i);
        }
        return -1;
    }

    uint8 private constant PICK_FORFEIT_CLOSED = 0;    // forfeitable, window closed
    uint8 private constant PICK_FLAT_FORFEIT_OPEN = 1; // flat, forfeitable, window open
    uint8 private constant PICK_SHORT_R = 2;           // unarmed, live, R < 2 * SIX_DAYS

    /// @dev `_pick` restricted to the state a probe needs, so the probe fires
    ///      whenever such a position exists.
    function _pickFor(uint256 rand, uint8 mode) internal view returns (int256) {
        uint256 n = shadows.length;
        if (n == 0) return -1;
        uint256 start = rand % n;
        for (uint256 k; k < n; ++k) {
            uint256 i = (start + k) % n;
            Shadow storage s = shadows[i];
            if (!s.alive) continue;
            bool ok;
            if (mode == PICK_FORFEIT_CLOSED) {
                ok = s.forfeitable && s.transferableAfter != 0 && block.timestamp >= s.transferableAfter;
            } else if (mode == PICK_FLAT_FORFEIT_OPEN) {
                ok = s.autoRelockRemaining != 0 && s.forfeitable && s.transferableAfter > block.timestamp;
            } else {
                ok = s.autoRelockRemaining == 0 && s.amount > 0 && s.end > block.timestamp
                    && _bucketR(uint256(s.end), block.timestamp) < 2 * SIX_DAYS;
            }
            if (ok) return int256(i);
        }
        return -1;
    }

    function _push(uint256 tokenId, uint256 amount, uint64 end, uint64 transferableAfter, bool forfeitable)
        internal
    {
        shadows.push(Shadow({
            tokenId: tokenId,
            alive: true,
            amount: int128(uint128(amount)),
            end: end,
            transferableAfter: transferableAfter,
            forfeitable: forfeitable,
            autoRelockRemaining: 0
        }));
        createdAt[tokenId] = uint64(block.timestamp);
    }

    function _burn(Shadow storage s) internal {
        s.alive = false;
        burnedAt[s.tokenId] = uint64(block.timestamp);
    }

    /// @dev The ledger side of leaving flat (disable, keeper retire, armed
    ///      transfer): the stored end becomes `grid(now) + R`.
    function _authorDisarm(Shadow storage s) internal {
        s.end = uint64(_grid(block.timestamp) + uint256(s.autoRelockRemaining));
        s.autoRelockRemaining = 0;
        authoredRefreshedAt[s.tokenId] = 0;
    }

    /// @dev Called after every mutating action: a mutation in the same second
    ///      as a past-supply sample invalidates that sample.
    function _invalidateSameSecondSamples() internal {
        for (uint256 k = pastSupplySamples.length; k > 0; --k) {
            if (pastSupplySamples[k - 1].timestamp != block.timestamp) break;
            pastSupplySamples[k - 1].valid = false;
        }
    }

    // ---------------------------------------------------------------------
    // ledger views
    // ---------------------------------------------------------------------
    function authoredSlope(uint256 i) public view returns (uint256) {
        return uint256(uint128(shadows[i].amount)) / MAX_TIME;
    }

    /// @notice Ledger weight of shadow `i` at `block.timestamp`.
    /// @dev The flat level is the bucket mean, `slope * (R - SIX_DAYS/2)`.
    ///      R is at least `2 * SIX_DAYS` and SIX_DAYS is even, so this is
    ///      exact.
    function authoredWeight(uint256 i) public view returns (uint256) {
        Shadow storage s = shadows[i];
        if (!s.alive) return 0;
        return _authoredWeightAt(i, block.timestamp);
    }

    function _authoredWeightAt(uint256 i, uint256 t) internal view returns (uint256) {
        Shadow storage s = shadows[i];
        if (s.amount <= 0) return 0;
        uint256 slope = authoredSlope(i);
        if (s.autoRelockRemaining != 0) return slope * (uint256(s.autoRelockRemaining) - SIX_DAYS / 2);
        if (uint256(s.end) <= t) return 0;
        return slope * (uint256(s.end) - t);
    }

    /// @notice Ledger total at `t <= now` for positions alive at `t`.
    function authoredTotalAt(uint256 t) public view returns (uint256 total) {
        uint256 n = shadows.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = shadows[i].tokenId;
            if (uint256(createdAt[id]) > t) continue;
            uint64 burnedAtTime = burnedAt[id];
            if (burnedAtTime != 0 && uint256(burnedAtTime) <= t) continue;
            if (!shadows[i].alive && burnedAtTime == 0) continue;
            total += _authoredWeightAt(i, t);
        }
    }

    /// @notice Ledger subcurve weight: a plain ramp to `min(end, transferableAfter)`
    ///         whether or not the position is flat (auto-relock is invisible to
    ///         the subcurves).
    function authoredSubcurveWeight(uint256 i) public view returns (uint256) {
        Shadow storage s = shadows[i];
        if (!s.alive || s.amount <= 0) return 0;
        if (s.transferableAfter == 0 || s.transferableAfter <= block.timestamp) return 0;
        uint256 subEnd = s.end < s.transferableAfter ? s.end : s.transferableAfter;
        if (subEnd <= block.timestamp) return 0;
        return authoredSlope(i) * (subEnd - block.timestamp);
    }

    /// @dev The weight step at the current instant, as `(up, down)`: enable
    ///      moves the decaying weight `slope * (R - off)` to the flat level
    ///      `slope * (R - S/2)`, i.e. by `slope * (off - S/2)`; a disable or
    ///      retire moves it back, by the negation. `off = now - grid(now)`.
    function _expectedWeightStep(uint256 i, bool enable) internal view returns (uint256 up, uint256 down) {
        uint256 slope = authoredSlope(i);
        uint256 rise = slope * (block.timestamp - _grid(block.timestamp));
        uint256 half = slope * (SIX_DAYS / 2);
        uint256 stepUp;
        uint256 stepDown;
        if (rise >= half) stepUp = rise - half;
        else stepDown = half - rise;
        return enable ? (stepUp, stepDown) : (stepDown, stepUp);
    }

    /// @dev Error of an observed step against `_expectedWeightStep`, and whether either
    ///      direction reached a whole bucket of the position's own slope.
    function _stepErr(uint256 i, bool enable, uint256 weightBefore, uint256 weightAfter)
        internal
        view
        returns (uint256 err, bool overBucket)
    {
        (uint256 up, uint256 down) = _expectedWeightStep(i, enable);
        uint256 observedUp = weightAfter > weightBefore ? weightAfter - weightBefore : 0;
        uint256 observedDown = weightBefore > weightAfter ? weightBefore - weightAfter : 0;
        uint256 upErr = observedUp > up ? observedUp - up : up - observedUp;
        uint256 downErr = observedDown > down ? observedDown - down : down - observedDown;
        err = upErr > downErr ? upErr : downErr;
        uint256 bucket = authoredSlope(i) * SIX_DAYS;
        overBucket = observedUp >= bucket || observedDown >= bucket;
    }

    /// @dev `fail_on_revert` does not see a delegation revert the contract
    ///      catches; count the `DelegationUpdateFailed` events instead.
    function _tallyDelegationFailures() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("DelegationUpdateFailed(uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                unchecked { delegationUpdateFailedCount += 1; }
            }
        }
    }

    // ---------------------------------------------------------------------
    // position creation and seeding
    // ---------------------------------------------------------------------
    function createLock(uint256 amount, uint256 duration) public {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);
        uint64 end = uint64(_grid(block.timestamp + duration));
        if (end <= block.timestamp) return;
        address who = _sender();
        vm.startPrank(who);
        hemi.mint(who, amount);
        hemi.approve(address(veHemi), amount);
        uint256 id = veHemi.createLock(amount, duration);
        vm.stopPrank();
        _push(id, amount, end, 0, false);
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    function createLockedPosition(uint256 amount, uint256 duration) public {
        _createNonTransferable(amount, duration, false);
    }

    function createForfeitablePosition(uint256 amount, uint256 duration) public {
        _createNonTransferable(amount, duration, true);
    }

    function _createNonTransferable(uint256 amount, uint256 duration, bool forfeitable) internal {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);
        uint64 end = uint64(_grid(block.timestamp + duration));
        if (end <= block.timestamp) return;
        vm.startPrank(admin);
        hemi.mint(admin, amount);
        hemi.approve(address(veHemi), amount);
        uint256 id = veHemi.createLockFor(amount, duration, _sender(), false, forfeitable);
        vm.stopPrank();
        _push(id, amount, end, end, forfeitable);
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    /// @notice Run the seeding flow (test setup only; excluded from fuzzing).
    ///         Until `lockedSeedingFinalized`, the contract refuses enables on
    ///         non-transferable positions.
    function seedNow() public {
        if (seeded) return;
        vm.startPrank(admin);
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
        vm.stopPrank();
        seeded = true;
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    // ---------------------------------------------------------------------
    // enable / disable
    // ---------------------------------------------------------------------
    function enableAutoRelock(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, false);
        if (pick < 0) return;
        uint256 i = uint256(pick);
        Shadow storage s = shadows[i];
        if (s.amount <= 0) return;
        if (s.end <= block.timestamp) return;
        uint256 r = _bucketR(uint256(s.end), block.timestamp);
        if (r < 2 * SIX_DAYS) return;                                       // AutoRelockDurationTooShort
        if (!veHemi.lockedSeedingFinalized() && s.transferableAfter > block.timestamp) return; // SeedingNotFinalized
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;

        uint256 weightBefore = veHemi.balanceOfNFT(s.tokenId);
        vm.recordLogs();
        vm.prank(owner);
        veHemi.enableAutoRelock(s.tokenId);
        _tallyDelegationFailures();

        s.autoRelockRemaining = uint64(r);
        authoredRefreshedAt[s.tokenId] = uint64(block.timestamp); // enable sets the refresh stamp too
        unchecked { enables += 1; }

        (uint256 stepErr, bool overBucket) = _stepErr(i, true, weightBefore, veHemi.balanceOfNFT(s.tokenId));
        if (stepErr != 0) {
            unchecked { enableStepNotExact += 1; }
            if (stepErr > maxEnableStepErrWei) maxEnableStepErrWei = stepErr;
        }
        if (overBucket) { unchecked { enableStepOverBucket += 1; } }
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    /// @notice Enable shadow `idx` without mirroring the preconditions (test
    ///         setup only; excluded from fuzzing).
    function enableAutoRelockUnchecked(uint256 idx) public {
        Shadow storage s = shadows[idx];
        uint256 r = _bucketR(uint256(s.end), block.timestamp);
        vm.prank(_ownerOfSafe(s.tokenId));
        veHemi.enableAutoRelock(s.tokenId);
        s.autoRelockRemaining = uint64(r);
        authoredRefreshedAt[s.tokenId] = uint64(block.timestamp);
        unchecked { enables += 1; }
        _invalidateSameSecondSamples();
    }

    function disableAutoRelock(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        uint256 i = uint256(pick);
        Shadow storage s = shadows[i];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;

        uint256 weightBefore = veHemi.balanceOfNFT(s.tokenId);
        vm.recordLogs();
        vm.prank(owner);
        veHemi.disableAutoRelock(s.tokenId);
        _tallyDelegationFailures();

        _authorDisarm(s);
        unchecked { disables += 1; }

        (uint256 stepErr, bool overBucket) = _stepErr(i, false, weightBefore, veHemi.balanceOfNFT(s.tokenId));
        if (stepErr != 0) {
            unchecked { disableStepNotExact += 1; }
            if (stepErr > maxDisableStepErrWei) maxDisableStepErrWei = stepErr;
        }
        if (overBucket) { unchecked { disableStepOverBucket += 1; } }
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    /// @dev Draw-weight aliases: the fuzzer picks selectors uniformly, so the
    ///      feature's two transitions get one extra selector each.
    function enableAutoRelockExtraDraw(uint256 rand) public { enableAutoRelock(rand); }
    function disableAutoRelockExtraDraw(uint256 rand) public { disableAutoRelock(rand); }

    // ---------------------------------------------------------------------
    // ordinary mutations
    // ---------------------------------------------------------------------
    function increaseAmount(uint256 rand, uint256 amount) public {
        _topUp(rand, bound(amount, MIN_AMOUNT, MAX_AMOUNT));
    }

    /// @notice The owner tops up by 1 wei .. 1 HEMI (a small top-up reaches the
    ///         same `_depositFor` body as a large one).
    function increaseAmountSmall(uint256 rand, uint256 amount) public {
        _topUp(rand, bound(amount, 1, 1e18));
    }

    function _topUp(uint256 rand, uint256 amount) internal {
        int256 pick = _pick(rand);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        if (s.amount <= 0) return;
        if (s.autoRelockRemaining == 0 && s.end <= block.timestamp) return;
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        if (veHemi.seedingStarted() && !veHemi.lockedSeedingFinalized() && s.transferableAfter != 0) return;

        vm.recordLogs();
        vm.startPrank(owner);
        hemi.mint(owner, amount);
        hemi.approve(address(veHemi), amount);
        veHemi.increaseAmount(s.tokenId, amount);
        vm.stopPrank();
        _tallyDelegationFailures();

        // A flat position touched by a top-up has its stored end
        // re-materialised to `grid(now) + R`.
        if (s.autoRelockRemaining != 0) s.end = uint64(_grid(block.timestamp) + uint256(s.autoRelockRemaining));
        s.amount += int128(uint128(amount));
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    /// @notice A non-owner's top-up is refused with `NotOwner` and moves
    ///         nothing (asserted here, so a bypass fails the run).
    function increaseAmountByStranger(uint256 rand, uint256 amount, uint256 whoIdx) public {
        amount = bound(amount, 1, 1e18);
        int256 pick = _pick(rand);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        if (s.amount <= 0) return;
        if (s.autoRelockRemaining == 0 && s.end <= block.timestamp) return;
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        address who = users[whoIdx % users.length];
        if (who == owner) who = users[(whoIdx % users.length + 1) % users.length];
        if (veHemi.seedingStarted() && !veHemi.lockedSeedingFinalized() && s.transferableAfter != 0) return;

        int128 amountBefore = veHemi.getLockedBalance(s.tokenId).amount;
        uint64 remainingBefore = veHemi.autoRelockRemaining(s.tokenId);
        vm.startPrank(who);
        hemi.mint(who, amount);
        hemi.approve(address(veHemi), amount);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseAmount(s.tokenId, amount);
        vm.stopPrank();
        require(veHemi.getLockedBalance(s.tokenId).amount == amountBefore, "refused top-up moved the lock");
        require(veHemi.autoRelockRemaining(s.tokenId) == remainingBefore, "refused top-up moved R");
    }

    function increaseUnlockTime(uint256 rand, uint256 duration) public {
        _increaseUnlockTime(rand, duration, false);
    }

    /// @notice Same, restricted to flat positions (an undirected draw rarely
    ///         lands on one).
    function increaseUnlockTimeFlat(uint256 rand, uint256 duration) public {
        _increaseUnlockTime(rand, duration, true);
    }

    function _increaseUnlockTime(uint256 rand, uint256 duration, bool wantFlat) internal {
        int256 pick = wantFlat ? _pickByFlatness(rand, true) : _pick(rand);
        if (pick < 0) return;
        uint256 i = uint256(pick);
        Shadow storage s = shadows[i];
        if (s.amount <= 0) return;
        if (s.autoRelockRemaining != 0) {
            _extendWhileFlat(i, duration);
            return;
        }
        if (s.end <= block.timestamp) return;
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        if (veHemi.seedingStarted() && !veHemi.lockedSeedingFinalized() && s.transferableAfter != 0) return;

        uint256 remainingDuration = uint256(s.end) - block.timestamp;
        if (remainingDuration + SIX_DAYS > MAX_DURATION) return;
        duration = bound(duration, remainingDuration + SIX_DAYS, MAX_DURATION);
        uint64 newEnd = uint64(_grid(block.timestamp + duration));
        if (uint256(newEnd) > block.timestamp + MAX_TIME) return;
        if (newEnd <= s.end) return;

        vm.recordLogs();
        vm.prank(owner);
        veHemi.increaseUnlockTime(s.tokenId, duration);
        _tallyDelegationFailures();

        s.end = newEnd;
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    /// @dev `increaseUnlockTime` on a flat position: the contract accepts it
    ///      and sets `R = unlockTime - grid(now)`. The weight must rise by
    ///      exactly `slope * (newR - R)`.
    function _extendWhileFlat(uint256 i, uint256 duration) internal {
        Shadow storage s = shadows[i];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        if (veHemi.seedingStarted() && !veHemi.lockedSeedingFinalized() && s.transferableAfter != 0) return;

        uint256 R = uint256(s.autoRelockRemaining);
        if (R + SIX_DAYS > MAX_TIME) return;
        duration = bound(duration, R + SIX_DAYS, MAX_TIME);
        uint256 unlockTime = _grid(block.timestamp + duration);
        if (unlockTime > block.timestamp + MAX_TIME) return;   // LockDurationTooLong
        if (unlockTime <= _grid(block.timestamp) + R) return;  // NewLockDurationNotGreater
        uint256 newR = unlockTime - _grid(block.timestamp);

        uint256 weightBefore = veHemi.balanceOfNFT(s.tokenId);
        vm.recordLogs();
        vm.prank(owner);
        veHemi.increaseUnlockTime(s.tokenId, duration);
        _tallyDelegationFailures();

        s.autoRelockRemaining = uint64(newR);
        s.end = uint64(unlockTime);
        unchecked { flatExtensions += 1; }

        uint256 expected = weightBefore + authoredSlope(i) * (newR - R);
        uint256 weightAfter = veHemi.balanceOfNFT(s.tokenId);
        if (weightAfter != expected) {
            unchecked { extendWeightViolations += 1; }
            uint256 errWei = weightAfter > expected ? weightAfter - expected : expected - weightAfter;
            if (errWei > maxExtendWeightErrWei) maxExtendWeightErrWei = errWei;
        }
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    // ---------------------------------------------------------------------
    // exits
    // ---------------------------------------------------------------------
    /// @dev Issue `withdraw` on a flat position (the ledger says flat, so it
    ///      must be refused at every timestamp, including past the stored end)
    ///      and record the outcome.
    function _probeFlatWithdraw(Shadow storage s, address flatOwner) internal {
        uint256 weight = veHemi.balanceOfNFT(s.tokenId);
        unchecked { flatWithdrawProbes += 1; }
        vm.prank(flatOwner);
        try veHemi.withdraw(s.tokenId) {
            unchecked { flatWithdrawSuccesses += 1; }
            if (weight > flatWithdrawWeightLeaked) flatWithdrawWeightLeaked = weight;
            // Keep the ledger true so the other checks report their own failures.
            _burn(s);
            s.autoRelockRemaining = 0;
            authoredRefreshedAt[s.tokenId] = 0;
        } catch (bytes memory err) {
            if (err.length < 4 || bytes4(err) != VeHemi.LockNotExpired.selector) {
                unchecked { flatWithdrawWrongError += 1; }
            }
        }
        _invalidateSameSecondSamples();
    }

    function withdraw(uint256 rand) public {
        int256 pick = _pick(rand);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        if (s.autoRelockRemaining != 0) {
            address flatOwner = _ownerOfSafe(s.tokenId);
            if (flatOwner == address(0)) return;
            _probeFlatWithdraw(s, flatOwner);
            return;
        }
        if (block.timestamp < s.end) return;
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;

        vm.recordLogs();
        vm.prank(owner);
        veHemi.withdraw(s.tokenId);
        _tallyDelegationFailures();

        _burn(s);
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    /// @notice `withdraw` probe drawn from the flat set (an undirected draw of
    ///         `withdraw` rarely lands on a flat position).
    function probeWithdrawWhileFlat(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address flatOwner = _ownerOfSafe(s.tokenId);
        if (flatOwner == address(0)) return;
        _probeFlatWithdraw(s, flatOwner);
    }

    function forfeit(uint256 rand) public {
        int256 pick = _pick(rand);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        if (!s.forfeitable) return;
        if (s.transferableAfter == 0 || block.timestamp >= s.transferableAfter) return;   // ForfeitWindowExpired
        if (s.end < block.timestamp) return;                // LockExpired (strict, on the stored end)
        if (_ownerOfSafe(s.tokenId) == address(0)) return;
        if (veHemi.seedingStarted() && !veHemi.lockedSeedingFinalized()) return;

        vm.recordLogs();
        vm.prank(veHemi.forfeitAdmin());
        veHemi.forfeit(s.tokenId);
        _tallyDelegationFailures();

        _burn(s);
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    /// @notice `forfeit` once the window has closed (`now >= transferableAfter`)
    ///         must be refused, even while the position is flat.
    function probeForfeitOutOfWindow(uint256 rand) public {
        int256 pick = _pickFor(rand, PICK_FORFEIT_CLOSED);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        if (!s.forfeitable) return;
        if (s.transferableAfter == 0 || block.timestamp < s.transferableAfter) return;
        if (_ownerOfSafe(s.tokenId) == address(0)) return;
        unchecked { forfeitOutOfWindowProbes += 1; }
        vm.prank(veHemi.forfeitAdmin());
        try veHemi.forfeit(s.tokenId) {
            unchecked { forfeitOutOfWindowAccepted += 1; }
            _burn(s);
        } catch {}
        _invalidateSameSecondSamples();
    }

    /// @notice `forfeit` inside the window on a flat position must be accepted:
    ///         `transferableAfter <= lock.end` for life, so the `LockExpired`
    ///         guard (which reads the stored end) cannot fire inside the window.
    function probeForfeitInWindowWhileFlat(uint256 rand) public {
        int256 pick = _pickFor(rand, PICK_FLAT_FORFEIT_OPEN);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        if (!s.forfeitable) return;
        if (s.transferableAfter == 0 || block.timestamp >= s.transferableAfter) return;
        if (s.amount <= 0) return;
        if (_ownerOfSafe(s.tokenId) == address(0)) return;
        if (veHemi.seedingStarted() && !veHemi.lockedSeedingFinalized()) return;
        unchecked { forfeitInWindowFlatProbes += 1; }
        vm.recordLogs();
        vm.prank(veHemi.forfeitAdmin());
        try veHemi.forfeit(s.tokenId) {
            _tallyDelegationFailures();
            _burn(s);
            maxWarp = MAX_ACCUMULATED_WARP;
        } catch {
            unchecked { forfeitInWindowFlatRefused += 1; }
        }
        _invalidateSameSecondSamples();
    }

    // ---------------------------------------------------------------------
    // transfer and delegation
    // ---------------------------------------------------------------------
    /// @dev A transfer to another account disarms an armed position; mirror
    ///      it in the ledger, or count a surviving flag as a violation.
    function _syncDisarmOnTransfer(uint256 i) internal {
        Shadow storage s = shadows[i];
        if (s.autoRelockRemaining == 0) return;
        if (veHemi.autoRelockRemaining(s.tokenId) != 0) { unchecked { transferDisarmMissed += 1; } return; }
        unchecked { transferDisarms += 1; }
        _authorDisarm(s);
    }

    function _transferableNow(Shadow storage s) internal view returns (bool) {
        return s.transferableAfter == 0 || block.timestamp >= s.transferableAfter;
    }

    /// @dev An alive, armed, currently transferable shadow, or -1.
    function _pickArmedTransferable(uint256 rand) internal view returns (int256) {
        uint256 n = shadows.length;
        if (n == 0) return -1;
        uint256 start = rand % n;
        for (uint256 k; k < n; ++k) {
            uint256 i = (start + k) % n;
            Shadow storage s = shadows[i];
            if (s.alive && s.autoRelockRemaining != 0 && _transferableNow(s)) return int256(i);
        }
        return -1;
    }

    /// @dev Arm an alive, unarmed, currently transferable shadow through
    ///      `enableAutoRelock` (which no-ops when a precondition fails); -1 if none.
    function _armATransferable(uint256 rand) internal returns (int256) {
        uint256 n = shadows.length;
        if (n == 0) return -1;
        uint256 start = rand % n;
        for (uint256 k; k < n; ++k) {
            uint256 i = (start + k) % n;
            Shadow storage s = shadows[i];
            if (!s.alive || s.autoRelockRemaining != 0 || !_transferableNow(s)) continue;
            enableAutoRelock(i); // `_pickByFlatness(i, false)` starts at i, which is alive and unarmed
            if (shadows[i].autoRelockRemaining != 0) return int256(i);
        }
        return -1;
    }

    /// @notice Transfer a position to `users[toIdx]`. On odd `rand` the
    ///         transfer is steered to an armed, transferable position (arming
    ///         one first if none exists), because create + arm + transfer
    ///         rarely line up on one position by chance.
    function transfer(uint256 rand, uint256 toIdx) public {
        address to = users[toIdx % users.length];
        int256 pick = _pick(rand);
        if (pick < 0) return;
        if (rand & 1 == 1) {
            int256 armed = _pickArmedTransferable(rand);
            if (armed < 0) armed = _armATransferable(rand);
            if (armed >= 0) pick = armed;
        }
        Shadow storage s = shadows[uint256(pick)];
        address from = _ownerOfSafe(s.tokenId);
        if (from == address(0) || from == to) return;
        if (s.transferableAfter != 0 && block.timestamp < s.transferableAfter) return;   // not transferable yet

        bool wasArmed = veHemi.autoRelockRemaining(s.tokenId) != 0;
        vm.recordLogs();
        vm.prank(from);
        veHemi.transferFrom(from, to, s.tokenId);
        _tallyDelegationFailures();
        _syncDisarmOnTransfer(uint256(pick));
        _scoreTransferRoute(s.tokenId, to, wasArmed);
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    /// @dev After a transfer the record must be a decaying record at the
    ///      recipient's delegate (`autoDelegate(to)`, or `to`). Scored when
    ///      VeHemi re-delegates: always for an armed transfer, and for an
    ///      unarmed one when the next hour boundary falls before `end`.
    function _scoreTransferRoute(uint256 id, address to, bool wasArmed) internal {
        uint256 end = uint256(veHemi.getLockedBalance(id).end);
        uint256 nextHourBoundary = (block.timestamp / 1 hours) * 1 hours + 1 hours;
        if (!wasArmed && nextHourBoundary >= end) return;
        address target = to;
        try delegation.autoDelegate(to) returns (address autoDelegatee) {
            if (autoDelegatee != address(0)) target = autoDelegatee;
        } catch {}
        try delegation.delegation(id) returns (IVeHemiVoteDelegation.Delegation memory record) {
            if (record.delegatee != target || (record.slope == 0 && record.bias > 0)) {
                unchecked { transferMisrouted += 1; }
            }
        } catch {}
    }

    /// @notice Re-delegate a position. The contract refuses an expired
    ///         decaying lock (`end <= next hour boundary`) and has no expiry
    ///         precondition for a flat one. Afterwards the record must be at
    ///         the chosen delegatee and keep its shape (flat or decaying).
    function delegate(uint256 rand, uint256 delegateeIdx) public {
        address delegatee = users[delegateeIdx % users.length];
        int256 pick = _pick(rand);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        uint256 nextHourBoundary = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;
        if (s.autoRelockRemaining == 0 && nextHourBoundary >= uint256(s.end)) return;
        vm.prank(owner);
        delegation.delegate(s.tokenId, delegatee);

        IVeHemiVoteDelegation.Delegation memory record = delegation.delegation(s.tokenId);
        unchecked { delegateRoutesChecked += 1; }
        bool flatRecord = record.slope == 0 && record.bias > 0;
        if (record.delegatee != delegatee || flatRecord != (s.autoRelockRemaining != 0)) {
            unchecked { delegateMisrouted += 1; }
        }
        _invalidateSameSecondSamples();
    }

    // ---------------------------------------------------------------------
    // time and sampling
    // ---------------------------------------------------------------------
    function checkpointOnly() public {
        veHemi.checkpoint();
        _invalidateSameSecondSamples();
    }

    function warp(uint256 time) public {
        if (maxWarp == 0) return;
        time = bound(time, 1, maxWarp);
        vm.warp(block.timestamp + time);
        maxWarp -= time;
    }

    function warpSmall(uint256 time) public {
        if (maxWarp == 0) return;
        uint256 cap = maxWarp < 3 hours ? maxWarp : 3 hours;
        time = bound(time, 1, cap);
        vm.warp(block.timestamp + time);
        maxWarp -= time;
    }

    /// @notice Record `(now, totalVeHemiSupplyAt(now), ledger total)` for
    ///         `checkPastSupplyImmutability` (at most 24 samples).
    function sampleSupply() public {
        _invalidateSameSecondSamples();
        if (pastSupplySamples.length < 24) {
            uint256 ts = block.timestamp;
            pastSupplySamples.push(
                PastSupplySample(ts, veHemi.totalVeHemiSupplyAt(ts), authoredTotalAt(ts), true)
            );
        }
    }

    // ---------------------------------------------------------------------
    // refusal probes
    // ---------------------------------------------------------------------
    /// @notice `withdraw` on a flat position, a second probe path.
    function probeFlatWithdrawBlocked(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        unchecked { flatWithdrawProbes += 1; }
        vm.prank(owner);
        try veHemi.withdraw(s.tokenId) {
            unchecked { flatWithdrawAccepted += 1; }
            _burn(s);
        } catch {}
        _invalidateSameSecondSamples();
    }

    /// @notice A second enable must be refused (`AutoRelockAlreadyEnabled`).
    function probeDoubleEnable(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        unchecked { doubleEnableProbes += 1; }
        vm.prank(owner);
        try veHemi.enableAutoRelock(s.tokenId) {
            unchecked { doubleEnableAccepted += 1; }
        } catch {}
        _invalidateSameSecondSamples();
    }

    /// @notice An enable with R < 2 * SIX_DAYS must be refused
    ///         (`AutoRelockDurationTooShort`); reachable for a lock in its last
    ///         two buckets.
    function probeEnableShortR(uint256 rand) public {
        int256 pick = _pickFor(rand, PICK_SHORT_R);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        if (s.amount <= 0 || s.end <= block.timestamp) return;
        if (_bucketR(uint256(s.end), block.timestamp) >= 2 * SIX_DAYS) return;
        if (!veHemi.lockedSeedingFinalized() && s.transferableAfter > block.timestamp) return;
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        unchecked { shortREnableProbes += 1; }
        vm.prank(owner);
        try veHemi.enableAutoRelock(s.tokenId) {
            unchecked { shortREnableAccepted += 1; }
            s.autoRelockRemaining = uint64(_bucketR(uint256(s.end), block.timestamp));
            authoredRefreshedAt[s.tokenId] = uint64(block.timestamp);
        } catch {}
        _invalidateSameSecondSamples();
    }

    /// @notice `disableAutoRelock` on a non-flat position must be refused.
    function probeDisableNotEnabled(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, false);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        unchecked { disableNotEnabledProbes += 1; }
        vm.prank(owner);
        try veHemi.disableAutoRelock(s.tokenId) {
            unchecked { disableNotEnabledAccepted += 1; }
        } catch {}
        _invalidateSameSecondSamples();
    }

    /// @notice While flat, an extension that does not strictly increase R must
    ///         be refused (`NewLockDurationNotGreater`).
    function probeExtendFlatShorter(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        uint256 R = uint256(s.autoRelockRemaining);
        if (R < 2 * SIX_DAYS) return;
        if (veHemi.seedingStarted() && !veHemi.lockedSeedingFinalized() && s.transferableAfter != 0) return;
        uint256 shorter = R - SIX_DAYS;
        unchecked { extendShorterProbes += 1; }
        vm.prank(owner);
        try veHemi.increaseUnlockTime(s.tokenId, shorter) {
            unchecked { extendShorterAccepted += 1; }
            uint256 unlockTime = _grid(block.timestamp + shorter);
            s.autoRelockRemaining = uint64(unlockTime - _grid(block.timestamp));
            s.end = uint64(unlockTime);
        } catch {}
        _invalidateSameSecondSamples();
    }

    /// @notice While flat, an extension past `now + MAX_TIME` must be refused
    ///         (`LockDurationTooLong`). `grid(now + MAX_TIME + SIX_DAYS) >
    ///         now + MAX_TIME` at every phase, so the input is always refused.
    function probeExtendFlatTooLong(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        if (veHemi.seedingStarted() && !veHemi.lockedSeedingFinalized() && s.transferableAfter != 0) return;
        uint256 duration = MAX_TIME + SIX_DAYS + (rand % SIX_DAYS);
        unchecked { extendTooLongProbes += 1; }
        vm.prank(owner);
        try veHemi.increaseUnlockTime(s.tokenId, duration) {
            unchecked { extendTooLongAccepted += 1; }
        } catch {}
        _invalidateSameSecondSamples();
    }

    // ---------------------------------------------------------------------
    // SIX_DAYS bucket-boundary transitions. `warp` and `warpSmall` draw
    // arbitrary seconds and essentially never land on `now % SIX_DAYS == 0`;
    // these actions construct the bucket-boundary instant and the transitions
    // at it.
    // ---------------------------------------------------------------------
    function _atPhaseZero() internal view returns (bool) {
        return block.timestamp % SIX_DAYS == 0;
    }

    /// @dev Warp exactly to `target`, within the accumulated-warp budget.
    function _warpExact(uint256 target) internal returns (bool) {
        if (target < block.timestamp) return false;
        uint256 delta = target - block.timestamp;
        if (delta > maxWarp) return false;
        if (delta != 0) {
            vm.warp(target);
            maxWarp -= delta;
        }
        return true;
    }

    /// @notice Land on the k-th next SIX_DAYS bucket boundary (k in 1..4) and
    ///         checkpoint there.
    function warpToBucketBoundary(uint256 rand) public {
        if (maxWarp == 0) return;
        uint256 k = 1 + (rand % 4);
        uint256 target = (block.timestamp / SIX_DAYS + k) * SIX_DAYS;
        if (!_warpExact(target)) return;
        require(_atPhaseZero(), "warpToBucketBoundary missed phase 0");
        veHemi.checkpoint();
        unchecked { bucketBoundaryCheckpoints += 1; }
        _invalidateSameSecondSamples();
    }

    /// @notice Warp to the next bucket boundary, create a two-bucket lock
    ///         there and enable it, so the enable's checkpoint lands on the
    ///         bucket boundary.
    function createAndEnableAtBucketBoundary(uint256 rand) public {
        if (maxWarp == 0) return;
        uint256 delta = (SIX_DAYS - block.timestamp % SIX_DAYS) % SIX_DAYS;
        if (delta > maxWarp) return;
        if (delta != 0) {
            vm.warp(block.timestamp + delta);
            maxWarp -= delta;
        }
        require(_atPhaseZero(), "createAndEnableAtBucketBoundary missed phase 0");
        uint256 amount = MIN_AMOUNT + (rand % (MAX_AMOUNT - MIN_AMOUNT));
        address who = _sender();
        uint64 end = uint64(_grid(block.timestamp + MIN_DURATION));
        if (end <= block.timestamp) return;
        vm.startPrank(who);
        hemi.mint(who, amount);
        hemi.approve(address(veHemi), amount);
        uint256 id = veHemi.createLock(amount, MIN_DURATION);
        vm.stopPrank();
        _push(id, amount, end, 0, false);
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
        uint256 idx = shadows.length - 1;
        enableAutoRelock(idx);
        if (shadows[idx].autoRelockRemaining != 0) { unchecked { bucketBoundaryEnables += 1; } }
    }

    /// @notice Warp to a decaying position's own (grid-aligned) end and
    ///         withdraw there: the `oldEnd == now` branch of the slope-change
    ///         bookkeeping, at a bucket boundary.
    function withdrawAtExactEnd(uint256 rand) public {
        uint256 n = shadows.length;
        if (n == 0) return;
        uint256 start = rand % n;
        for (uint256 k; k < n; ++k) {
            uint256 i = (start + k) % n;
            Shadow storage s = shadows[i];
            if (!s.alive) continue;
            if (s.autoRelockRemaining != 0) continue;
            uint256 end = uint256(s.end);
            if (end % SIX_DAYS != 0) continue;
            if (end < block.timestamp) continue;
            if (end - block.timestamp > maxWarp) continue;
            address owner = _ownerOfSafe(s.tokenId);
            if (owner == address(0)) continue;
            if (!_warpExact(end)) return;
            require(_atPhaseZero(), "withdrawAtExactEnd missed phase 0");
            vm.recordLogs();
            vm.prank(owner);
            veHemi.withdraw(s.tokenId);
            _tallyDelegationFailures();
            _burn(s);
            unchecked { bucketBoundaryExactEndWithdraws += 1; }
            maxWarp = MAX_ACCUMULATED_WARP;
            _invalidateSameSecondSamples();
            return;
        }
    }

    /// @notice Warp to a transferable decaying position's end and transfer it
    ///         there (`oldEnd == newEnd == now`, on a bucket boundary).
    function transferAtExactEnd(uint256 rand) public {
        uint256 n = shadows.length;
        if (n == 0) return;
        uint256 start = rand % n;
        for (uint256 k; k < n; ++k) {
            uint256 i = (start + k) % n;
            Shadow storage s = shadows[i];
            if (!s.alive) continue;
            if (s.autoRelockRemaining != 0) continue;
            if (s.transferableAfter != 0) continue;
            uint256 end = uint256(s.end);
            if (end % SIX_DAYS != 0) continue;
            if (end < block.timestamp) continue;
            if (end - block.timestamp > maxWarp) continue;
            address owner = _ownerOfSafe(s.tokenId);
            if (owner == address(0)) continue;
            address to = users[(rand >> 8) % users.length];
            if (to == owner || to == address(0)) continue;
            if (!_warpExact(end)) return;
            require(_atPhaseZero(), "transferAtExactEnd missed phase 0");
            vm.recordLogs();
            vm.prank(owner);
            veHemi.transferFrom(owner, to, s.tokenId);
            _tallyDelegationFailures();
            unchecked { bucketBoundaryExactEndTransfers += 1; }
            maxWarp = MAX_ACCUMULATED_WARP;
            _invalidateSameSecondSamples();
            return;
        }
    }

    // ---------------------------------------------------------------------
    // keeper paths: the owner heartbeat and the permissionless stale retire
    // ---------------------------------------------------------------------
    /// @notice `refreshAutoRelock` (owner-only) must set `autoRelockStaleAt`
    ///         to `now + STALE_FLAT_BUCKETS * SIX_DAYS`.
    function ownerRefreshHeartbeat(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        vm.prank(owner);
        veHemi.refreshAutoRelock(s.tokenId);
        authoredRefreshedAt[s.tokenId] = uint64(block.timestamp);
        unchecked { heartbeatRefreshes += 1; }
        if (veHemi.autoRelockStaleAt(s.tokenId) != block.timestamp + EXPECTED_STALE_FLAT_BUCKETS * SIX_DAYS) {
            unchecked { abandonmentClockViolations += 1; }
        }
        _invalidateSameSecondSamples();
    }

    /// @notice `refreshAutoRelock` from a non-owner must be refused.
    function probeRefreshByStranger(uint256 rand, uint256 whoIdx) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        address who = users[whoIdx % users.length];
        if (who == owner) who = users[((whoIdx % users.length) + 1) % users.length];
        if (who == owner) return;
        unchecked { refreshStrangerProbes += 1; }
        vm.prank(who);
        try veHemi.refreshAutoRelock(s.tokenId) {
            unchecked { refreshStrangerAccepted += 1; }
        } catch {}
        _invalidateSameSecondSamples();
    }

    /// @notice `refreshAutoRelock` on a non-flat position must be refused
    ///         (`AutoRelockNotEnabled`).
    function probeRefreshNotEnabled(uint256 rand) public {
        int256 pick = _pickByFlatness(rand, false);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        unchecked { refreshNotEnabledProbes += 1; }
        vm.prank(owner);
        try veHemi.refreshAutoRelock(s.tokenId) {
            unchecked { refreshNotEnabledAccepted += 1; }
        } catch {}
        _invalidateSameSecondSamples();
    }

    /// @notice `retireStaleAutoRelock` before `autoRelockStaleAt` must be
    ///         refused (`AutoRelockNotStale`).
    function probeRetireNotStale(uint256 rand, uint256 whoIdx) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        Shadow storage s = shadows[uint256(pick)];
        if (_ownerOfSafe(s.tokenId) == address(0)) return;
        if (block.timestamp >= veHemi.autoRelockStaleAt(s.tokenId)) return;
        unchecked { staleRetireEarlyProbes += 1; }
        vm.prank(users[whoIdx % users.length]);
        try veHemi.retireStaleAutoRelock(s.tokenId) {
            unchecked { staleRetireEarlyAccepted += 1; }
        } catch {}
        _invalidateSameSecondSamples();
    }

    /// @notice Warp to a flat position's `autoRelockStaleAt` and retire it
    ///         from a non-owner. The ledger authors the same restored end as
    ///         an owner disable, and the weight step must be the same closed
    ///         form.
    function keeperRetireStale(uint256 rand, uint256 whoIdx) public {
        int256 pick = _pickByFlatness(rand, true);
        if (pick < 0) return;
        uint256 i = uint256(pick);
        Shadow storage s = shadows[i];
        address owner = _ownerOfSafe(s.tokenId);
        if (owner == address(0)) return;
        uint256 staleAt = veHemi.autoRelockStaleAt(s.tokenId);
        if (staleAt > block.timestamp) {
            if (staleAt - block.timestamp > maxWarp) return;
            if (!_warpExact(staleAt)) return;
        }
        address who = users[whoIdx % users.length];
        if (who == owner) who = users[((whoIdx % users.length) + 1) % users.length];

        uint256 weightBefore = veHemi.balanceOfNFT(s.tokenId);
        vm.recordLogs();
        vm.prank(who);
        veHemi.retireStaleAutoRelock(s.tokenId);
        _tallyDelegationFailures();

        _authorDisarm(s);
        unchecked { staleRetires += 1; }

        (uint256 stepErr,) = _stepErr(i, false, weightBefore, veHemi.balanceOfNFT(s.tokenId));
        if (stepErr != 0) {
            unchecked { staleRetireStepNotExact += 1; }
            if (stepErr > maxStaleRetireStepErrWei) maxStaleRetireStepErrWei = stepErr;
        }
        maxWarp = MAX_ACCUMULATED_WARP;
        _invalidateSameSecondSamples();
    }

    // ---------------------------------------------------------------------
    // the delegation module's permissionless expiry amortiser
    // ---------------------------------------------------------------------
    /// @notice Write the expiry checkpoint for the first user, from a
    ///         fuzz-chosen offset, that has expired delegations pending.
    function writeExpiredCheckpoint(uint256 delegateeIdx) public {
        for (uint256 k; k < users.length; ++k) {
            address delegatee = users[(delegateeIdx % users.length + k) % users.length];
            if (delegation.calculateExpiredDelegations(delegatee).timestamp == 0) continue;
            delegation.writeNewCheckpointForExpiredDelegations(delegatee);
            unchecked { ++expiredCheckpointWrites; }
            _invalidateSameSecondSamples();
            return;
        }
    }
}
