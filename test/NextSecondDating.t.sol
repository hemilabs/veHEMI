// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title NextSecondDatingTest
/// @notice What `t+1` delegation dating leaves in place, asserted:
///         a same-block flash delegation is unreadable (B2); a transfer
///         credits the recipient from the next second, so a one-second hold
///         reaches any snapshot instant (B3, by design); the emitted
///         `DelegateVotesChanged.newVotes` equals the votes at the instant the
///         change takes effect (C1); the `forfeit` phantom lasts at most one
///         second (D1); and on an armed non-transferable position
///         `supplyBreakdown().locked` exceeds `total` by at most the
///         bucket-mean half-bucket term (F1).
contract NextSecondDatingTest is LockedCurveTestBase {
    address internal constant MALLORY  = address(0xBAD0);
    address internal constant LENDER   = address(0x1EDE);
    address internal constant MAL_DEL  = address(0xDEAD01);
    address internal constant DEL_A    = address(0xA1);
    address internal constant VICTIM   = address(0x1C70);
    address internal constant FADMIN   = address(0xFADA);

    function _b(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }

    // B2. A SAME-BLOCK FLASH DELEGATION IS UNREADABLE, LIVE AND HISTORICALLY.
    function test_B2_sameBlockFlashDelegationIsUnreadable() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(LENDER, 500 ether, 40 * SIX_DAYS);
        vm.prank(MALLORY); delegation.setAutoDelegate(MAL_DEL);

        uint256 T = _b(block.timestamp) + 1234;
        vm.warp(T);
        vm.prank(LENDER); veHemi.transferFrom(LENDER, MALLORY, id);

        uint256 liveSameBlock = delegation.getVotes(MAL_DEL);
        uint256 pastSameBlock = delegation.getPastVotes(MAL_DEL, T);
        vm.expectRevert();
        delegation.getPastVotes(MAL_DEL, T + 1);

        emit log_named_uint("B2 getVotes in the SAME block   ", liveSameBlock);
        emit log_named_uint("B2 getPastVotes(T) same block   ", pastSameBlock);

        assertEq(liveSameBlock, 0, "B2: same-block flash delegation is unreadable");
        assertEq(pastSameBlock, 0, "B2: and unreadable historically at T");
    }

    // B3. A ONE-SECOND HOLD REACHES EVERY SNAPSHOT INSTANT (BY DESIGN).
    //   For 11 snapshot instants spread across one bucket, acquiring the
    //   position one second before the snapshot already credits the new
    //   holder's delegatee at the snapshot: the transfer is booked at t+1.
    function test_B3_oneSecondHoldCreditsEverySnapshotInstant() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(LENDER, 500 ether, 40 * SIX_DAYS);
        vm.prank(MALLORY); delegation.setAutoDelegate(MAL_DEL);
        uint256 B0 = _b(block.timestamp) + 1 hours;

        uint256 worst;      // max over sampled S of the minimum hold
        for (uint256 k = 300; k < 3600; k += 300) {
            uint256 S = B0 + k;
            // walk back from S-1 until acquisition credits S
            uint256 hold = type(uint256).max;
            uint16[15] memory probes = [1, 2, 5, 10, 30, 60, 120, 300, 600, 900, 1200, 1800, 2400, 3000, 3600];
            for (uint256 j = 0; j < probes.length; ++j) {
                uint256 back = probes[j];
                if (S < back) break;
                uint256 snap = vm.snapshotState();
                vm.warp(S - back);
                vm.prank(LENDER); veHemi.transferFrom(LENDER, MALLORY, id);
                vm.warp(S);
                bool credited = delegation.getVotes(MAL_DEL) > 0;
                vm.revertToState(snap);
                if (credited) { hold = back; break; }
            }
            if (hold == type(uint256).max) hold = 3601;   // never credited in the hour
            if (hold > worst) worst = hold;
        }

        assertLe(worst, 1, "B3: some snapshot instant needs more than a one-second hold");
    }

    // =====================================================================
    // C1. THE EVENT / ADAPTER SEAM. `DelegateVotesChanged.newVotes` -- the
    //     number relayed to the Aragon adapter and indexed by its subgraph --
    //     equals the delegatee's votes at the first instant the change is
    //     effective (`block.timestamp + 1`).
    // =====================================================================
    function test_C1_eventNewVotesEqualsEffectiveVotes() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 40 * SIX_DAYS);

        uint256 B0 = _b(block.timestamp) + 1 hours;
        uint256 T  = B0 + 1;                      // as early in the bucket as possible
        vm.warp(T);

        vm.recordLogs();
        vm.prank(alice); delegation.delegate(id, DEL_A);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 emittedNewVotes;
        bytes32 sig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == sig
                && logs[i].topics[1] == bytes32(uint256(uint160(DEL_A)))) {
                (, uint256 nv) = abi.decode(logs[i].data, (uint256, uint256));
                emittedNewVotes = nv;
            }
        }

        // Find the EFFECTIVE instant empirically: the first second at which
        // the delegatee's live votes stop being zero.
        uint256 effective;
        for (uint256 t = T + 1; t <= B0 + 3600; ++t) {
            vm.warp(t);
            if (delegation.getVotes(DEL_A) != 0) { effective = t; break; }
        }
        vm.warp(effective);
        uint256 actualAtEffective = delegation.getVotes(DEL_A);
        vm.warp(B0 + 3600);
        uint256 actualAtBoundary = delegation.getVotes(DEL_A);

        emit log_named_uint("C1 delegation made at T         ", T);
        emit log_named_uint("C1 FIRST effective instant      ", effective);
        emit log_named_uint("C1 emitted/relayed newVotes     ", emittedNewVotes);
        emit log_named_uint("C1 getVotes at effective instant", actualAtEffective);
        emit log_named_uint("C1 getVotes at the boundary     ", actualAtBoundary);
        emit log_named_uint("C1 |relayed - effective| wei    ",
            emittedNewVotes > actualAtEffective ? emittedNewVotes - actualAtEffective : actualAtEffective - emittedNewVotes);

        assertEq(emittedNewVotes, actualAtEffective,
            "C1: the relayed newVotes must equal the votes at the instant the change becomes effective");
    }

    // =====================================================================
    // D1. THE `forfeit` PHANTOM LASTS AT MOST ONE SECOND.
    //     Count the seconds in which the delegatee still votes against an
    //     escrow that is already ZERO.
    // =====================================================================
    function test_D1_forfeitPhantomIsOneSecond() public {
        veHemi.updateForfeitAdmin(FADMIN);
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);

        hemi.mint(address(this), 500 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 id = veHemi.createLockFor(500 ether, 40 * SIX_DAYS, VICTIM, false, true);
        vm.prank(VICTIM); delegation.delegate(id, DEL_A);

        uint256 B0 = _b(block.timestamp) + 1 hours;
        vm.warp(B0 + 60);                            // early in a bucket: widest exposure
        assertGt(delegation.getVotes(DEL_A), 0, "precondition");

        uint256 F = block.timestamp;
        vm.prank(FADMIN); veHemi.forfeit(id);

        uint256 phantom;
        for (uint256 t = F; t < B0 + 3600; ++t) {
            vm.warp(t);
            if (delegation.getVotes(DEL_A) > 0) { unchecked { ++phantom; } }
        }
        emit log_named_uint("D1 forfeit instant              ", F);
        emit log_named_uint("D1 phantom seconds (votes > 0,  ", phantom);
        emit log_named_uint("   escrow burned)               ", 0);

        assertLe(phantom, 1, "D1: the forfeit phantom is at most ONE second");
    }

    // =====================================================================
    // F1. `supplyBreakdown` ON AN ARMED NON-TRANSFERABLE POSITION.
    //     The position sits in the locked subcurve, so the breakdown is not
    //     vacuous. The global curve carries the bucket-mean flat level
    //     `slope * (R - SIX_DAYS/2)` while the locked subcurve decays toward
    //     `transferableAfter`, so in the first half of the arming bucket
    //     `locked` exceeds `total`, by at most `slope * SIX_DAYS / 2`, and
    //     `transferable` then saturates to 0. Sampled at 12 instants across
    //     the arming bucket and the next one.
    // =====================================================================
    function test_F1_supplyBreakdownBoundedOnArmedNonTransferable() public {
        runSeedingFlow();
        uint256 G = ((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS;
        vm.warp(G + 1000);                                   // first half of a bucket
        uint256 amount = 500 ether;
        hemi.mint(alice, amount);
        vm.prank(alice);
        uint256 id = veHemi.createLockWithAutoRelock(amount, 40 * SIX_DAYS, false, false);
        assertTrue(veHemi.isAutoRelockEnabled(id), "precondition: armed");
        assertFalse(veHemi.isTransferable(id), "precondition: non-transferable");

        uint256 bound = (amount / MAX_TIME) * (SIX_DAYS / 2);
        uint256 excessSamples;
        for (uint256 k = 0; k < 12; ++k) {
            vm.warp(G + 1000 + k * (SIX_DAYS / 6));
            (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable) = veHemi.supplyBreakdown();
            assertGt(locked_, 0, "F1: the locked subcurve does not carry the position");
            assertEq(forfeitable_, 0, "F1: no forfeitable position exists");
            if (locked_ > total) {
                ++excessSamples;
                assertLe(locked_ - total, bound, "F1: locked exceeds total by more than slope * SIX_DAYS / 2");
                assertEq(transferable, 0, "F1: transferable must saturate when locked > total");
            } else {
                assertEq(transferable, total - locked_, "F1: transferable != total - locked");
            }
        }
        assertGt(excessSamples, 0, "premise: no sample exercised locked > total");
    }
}
