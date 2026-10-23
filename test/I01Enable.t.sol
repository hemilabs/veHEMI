// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// ============================================================================
// The weight step of `enableAutoRelock` onto the bucket-mean flat level
// `slope * (R - SIX_DAYS/2)`.
// ----------------------------------------------------------------------------
// Enabling at phase `off` inside a SIX_DAYS bucket moves the weight by the
// signed closed form `slope * (off - SIX_DAYS/2)`: a LOSS in the first half of
// the bucket, bounded by `slope * SIX_DAYS/2` (relative bound 1/(2N)). The
// loss is not a burn: a disable restores the plain decaying ramp of the
// floor-snapped end (E2), and the midpoint-sampled step sums to exactly zero
// over a bucket (E3).
// ============================================================================

import "./TwinOracle.sol";

contract I01EnableTest is TwinOracle {
    address internal constant OWN = address(0x0FFE);
    uint256 internal constant AMT = 1000 ether;

    function setUp() public { setUpTwinOracle(); }
    function _driveCandidate(uint256) internal override {}
    function _id(uint256 i) internal view returns (uint256) { return positions[i].tokenId; }
    function _grid(uint256 t) internal pure returns (uint256) { return (t / SIX_DAYS) * SIX_DAYS; }

    // ==================================================================== E1
    /// @notice THE ENABLE STEP IS THE SIGNED CLOSED FORM AT EVERY PHASE AND
    ///         EVERY TERM, AND THE LOSS NEVER EXCEEDS slope * SIX_DAYS/2.
    ///
    ///         step == slope * off - slope * (SIX_DAYS/2)
    /// @dev ONE phase of ONE term (split out to stay below the stack limit
    ///      without via-ir). It RETURNS its result: the caller brackets every
    ///      phase in `snapshotState`/`revertToState`, which reverts contract
    ///      storage too.
    function _measureOneEnable(uint256 n, uint256 off) internal returns (uint256 loss) {
        vm.warp(t0 + off);
        vm.roll(block.number + 1);
        uint256 id = _id(spawn(true, OWN, AMT, n, Cadence.NEVER, false, false));
        uint256 before_ = X.ve.balanceOfNFT(id);
        vm.prank(OWN);
        X.ve.enableAutoRelock(id);
        uint256 after_ = X.ve.balanceOfNFT(id);

        // R is the whole-bucket remainder of the floor-snapped creation end.
        assertEq(uint256(X.ve.autoRelockRemaining(id)), n * SIX_DAYS, "E1 R != n buckets");
        assertEq(after_, meanLevelOf(AMT, n), "E1 level is not the bucket-mean flat level");

        uint256 rise = slopeOf(AMT) * off;
        uint256 half = slopeOf(AMT) * (SIX_DAYS / 2);
        if (rise >= half) {
            assertEq(after_ - before_, rise - half, "E1 enable RISE onto the bucket-mean level != slope*off - slope*S/2");
            return 0;
        }
        loss = before_ - after_;
        assertEq(loss, half - rise, "E1 enable LOSS onto the bucket-mean level != slope*S/2 - slope*off");
        assertLe(loss, half, "E1 loss exceeded slope * SIX_DAYS/2");   // THE BOUND
        uint256 bps = (loss * 10_000) / before_;
        // The tightest closed bound on the RELATIVE loss:
        //   loss/before = (S/2 - off) / (n*S - off) <= 1/(2n)
        assertLe(bps, 10_000 / (2 * n) + 1, "E1 relative loss exceeded 1/(2N)");
    }

    function test_E1_enable_step_closed_form_and_the_loss_bound() public {
        uint256 worstWei; uint256 lossPhases; uint256 phases;
        for (uint256 n = 2; n <= 8; ++n) {
            for (uint256 p; p < 12; ++p) {
                uint256 snap = vm.snapshotState();
                uint256 loss = _measureOneEnable(n, (p * SIX_DAYS) / 12);
                vm.revertToState(snap);
                phases += 1;
                if (loss != 0) {
                    lossPhases += 1;
                    if (loss > worstWei) worstWei = loss;
                }
            }
        }
        assertEq(phases, 84, "E1 did not measure 7 terms x 12 phases");
        // phases 0..5 of 12 lie in the first half of the bucket
        assertEq(lossPhases, 7 * 6, "E1 loss phases != the first half of every bucket");
        assertLe(worstWei, slopeOf(AMT) * (SIX_DAYS / 2), "E1 worst loss exceeded slope * SIX_DAYS/2");
    }

    // ==================================================================== E2
    /// @notice THE LOSS IS FULLY RESTORED AT DISABLE IN THE SAME PHASE.
    ///         enable at `off` then disable at the SAME `off` one bucket later
    ///         returns the position to the weight the manual twin would have.
    ///         That is what makes the loss a DEFERRAL, not a burn.
    function test_E2_the_loss_is_returned_at_disable() public {
        for (uint256 p; p < 12; ++p) {
            uint256 snap = vm.snapshotState();
            uint256 off = (p * SIX_DAYS) / 12;
            vm.warp(t0 + off);
            vm.roll(block.number + 1);
            uint256 i = spawn(true, OWN, AMT, 6, Cadence.NEVER, false, false);
            uint256 id = _id(i);
            vm.prank(OWN);
            X.ve.enableAutoRelock(id);
            // one full bucket later, at the SAME phase
            vm.warp(t0 + SIX_DAYS + off);
            vm.roll(block.number + 8766);
            vm.prank(OWN);
            X.ve.disableAutoRelock(id);
            uint256 restored = X.ve.balanceOfNFT(id);
            uint256 end = uint256(X.ve.getLockedBalance(id).end);
            // the restored end is grid(now) + R, R = 6 buckets
            assertEq(end, _grid(block.timestamp) + 6 * SIX_DAYS, "E2 restored end != grid(now) + R");
            assertEq(restored, slopeOf(AMT) * (end - block.timestamp), "E2 the restored weight is not the plain ramp of the restored end");
            vm.revertToState(snap);
        }
    }

    // ==================================================================== E3
    /// @notice ZERO-SUM OVER A BUCKET -- the reason the loss is acceptable, and
    ///         the reason a compensating mint is not needed.
    ///
    /// @dev SAMPLED AT MIDPOINTS, and that is not cosmetic. The bucket-mean
    ///      step is `slope*(off - S/2)`, so a LEFT-ENDPOINT 12-sample sum over
    ///      off = p*S/12 is `-slope*S/2` exactly -- a sampling artefact of the
    ///      grid. The midpoint grid off = (2p+1)*S/24 has mean exactly S/2
    ///      (S/24 = 21,915 s, an exact integer), so its sum is EXACTLY ZERO.
    function test_E3_the_step_is_zero_sum_across_the_bucket() public {
        int256 net;
        uint256 losses;
        uint256 rises;
        for (uint256 p; p < 12; ++p) {
            uint256 snap = vm.snapshotState();
            uint256 off = ((2 * p + 1) * SIX_DAYS) / 24;   // MIDPOINT of phase p
            vm.warp(t0 + off);
            vm.roll(block.number + 1);
            uint256 i = spawn(true, OWN, AMT, 6, Cadence.NEVER, false, false);
            uint256 id = _id(i);
            uint256 before_ = X.ve.balanceOfNFT(id);
            vm.prank(OWN);
            X.ve.enableAutoRelock(id);
            uint256 after_ = X.ve.balanceOfNFT(id);
            if (after_ >= before_) { net += int256(after_ - before_); if (after_ > before_) rises += 1; }
            else { net -= int256(before_ - after_); losses += 1; }
            vm.revertToState(snap);
        }
        assertEq(net, int256(0), "E3 midpoint net step onto the bucket-mean level is not EXACTLY zero");
        assertEq(losses, 6, "E3 the bucket-mean step must lose in exactly 6 of 12 midpoint phases");
        assertEq(rises, 6, "E3 the bucket-mean step must rise in exactly 6 of 12 midpoint phases");
    }
}
