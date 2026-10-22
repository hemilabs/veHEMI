// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";

/**
 * @title I04VoteHoleLaw
 * @notice The bound on the delegation vote hole, shared by the campaign
 *         check (`ARLChecks.checkVoteHoleBounded`) and the directed tests in
 *         test/I04VoteHole.t.sol.
 *
 * @dev WHAT THE HOLE IS. Every weight-changing write on a position runs
 *      `VeHemi._delegate` -> `VeHemiVoteDelegation._delegate`, which retires
 *      the position's old contribution and books the new one. Both legs are
 *      dated `_imm()` and the booking instant is stamped in
 *      `delegationBookedAt`: `block.timestamp + 1`, or the next hourly
 *      boundary inside the upgrade-hour window (`legacyDatingUntil`). A
 *      booking that matured later than its retirement would leave the
 *      position contributing zero to its delegatee in between, and because
 *      `getPastVotes` is keyed by timestamp the zero would be sealed into
 *      history. The clauses below bound that hole.
 *
 *      THE THREE CLAUSES, as state predicates evaluated at `block.timestamp`:
 *
 *      A — AT MOST ONE CHECKPOINT INTERVAL. For every token carrying a
 *          delegation record, `delegationBookedAt[id] <= nextBoundary(now)`.
 *          A booking may be pending, never pending past the very next hourly
 *          boundary, so any hole is strictly narrower than CHECKPOINT_INTERVAL
 *          and its end is fixed the moment the write lands.
 *
 *      A2 — NO ORPHAN STAMP. A token with no delegation record carries no
 *          maturity stamp (they are deleted together). A surviving stamp would
 *          be a hole with no way to close.
 *
 *      B — CONFINED, AND HEALED AT THE BOUNDARY. For every delegatee, the
 *          delegatee's live votes are AT LEAST the sum of the contributions of
 *          every token whose booking has already matured. A hole that reached a
 *          co-delegator (not confined) or a hole that outlived its own maturity
 *          stamp (not healed) both break this, and both break it in the wei.
 *          Deliberately `>=`: the over-count is bounded by
 *          `checkVotesNeverExceedSupply`; this law bounds the under-count.
 *
 *      The contribution of a matured record is read from the record the
 *      delegatee's checkpoint was built from — `delegations[id]` — with the
 *      shipped discriminator `(slope == 0 && bias > 0) == FLAT`:
 *      a flat term contributes its constant `bias` (it rides in `fixedBias`,
 *      untouched by decay, by the SIX_DAYS expiration walk and by the
 *      MAX_LOCK_DURATION wipe); a decaying term contributes
 *      `bias - slope * now` while `end > now` and nothing afterwards, which is
 *      exactly the arithmetic `_getDelegateVotesAt` performs on the aggregate.
 */
library I04VoteHoleLaw {
    /// @dev `private constant` in VeHemiVoteDelegation, restated here and
    ///      pinned against it in test/I04VoteHole.t.sol.
    uint256 internal constant CHECKPOINT_INTERVAL = 1 hours;
    uint256 internal constant EPOCH_OFFSET = 0;

    struct Report {
        uint256 lateMaturity;     // clause A violations
        uint256 maxLateBy;        // wei-equivalent: seconds past the next boundary
        uint256 orphanStamp;      // clause A2 violations
        uint256 shortfalls;       // clause B violations
        uint256 maxShortfallWei;  // worst under-count, in wei
        address worstDelegatee;
        uint256 inHole;           // COVERAGE: records observed mid-hole
        uint256 maxHoleWidth;     // COVERAGE: widest observed hole, seconds
        uint256 maturedCounted;   // COVERAGE: matured records the sum reached
    }

    function nextBoundary(uint256 t) internal pure returns (uint256) {
        return (((t - EPOCH_OFFSET) / CHECKPOINT_INTERVAL) * CHECKPOINT_INTERVAL)
            + CHECKPOINT_INTERVAL + EPOCH_OFFSET;
    }

    /// @dev The per-record contribution `_getDelegateVotesAt` aggregates.
    function contributionAt(
        uint256 slope_, uint256 bias_, uint256 end_, uint256 t_
    ) internal pure returns (uint256) {
        if (slope_ == 0) return bias_;            // FLAT (or an inert empty record)
        if (end_ <= t_) return 0;                 // swept by the SIX_DAYS walk
        uint256 decay = slope_ * t_;
        return bias_ > decay ? bias_ - decay : 0;
    }

    function scan(
        VeHemiVoteDelegation d_,
        uint256[] memory ids_,
        address[] memory delegatees_,
        uint256 t_
    ) internal view returns (Report memory r) {
        uint256[] memory matured = new uint256[](delegatees_.length);
        uint256 nb = nextBoundary(t_);

        for (uint256 i; i < ids_.length; ++i) {
            (address dg, uint48 end, uint96 bias, , uint64 slope) = d_.delegations(ids_[i]);
            uint256 bookedAt = uint256(d_.delegationBookedAt(ids_[i]));

            if (dg == address(0)) {
                if (bookedAt != 0) { unchecked { r.orphanStamp += 1; } }
                continue;
            }
            if (bookedAt > nb) {
                unchecked { r.lateMaturity += 1; }
                uint256 e = bookedAt - nb;
                if (e > r.maxLateBy) r.maxLateBy = e;
            }
            if (bookedAt > t_) {
                // MID-HOLE: the booking stamp is still in the future, so the
                // record has not matured and is not counted. Coverage, not a
                // violation.
                unchecked { r.inHole += 1; }
                uint256 w = bookedAt - t_;
                if (w > r.maxHoleWidth) r.maxHoleWidth = w;
                continue;
            }
            uint256 c = contributionAt(uint256(slope), uint256(bias), uint256(end), t_);
            if (c == 0) continue;
            for (uint256 k; k < delegatees_.length; ++k) {
                if (delegatees_[k] == dg) {
                    matured[k] += c;
                    unchecked { r.maturedCounted += 1; }
                    break;
                }
            }
        }

        for (uint256 k; k < delegatees_.length; ++k) {
            if (matured[k] == 0) continue;
            uint256 votes = d_.getVotes(delegatees_[k]);
            if (votes < matured[k]) {
                unchecked { r.shortfalls += 1; }
                uint256 s = matured[k] - votes;
                if (s > r.maxShortfallWei) { r.maxShortfallWei = s; r.worstDelegatee = delegatees_[k]; }
            }
        }
    }
}
