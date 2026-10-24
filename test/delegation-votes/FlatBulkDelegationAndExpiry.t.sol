// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {VeHemiAragonAdapter} from "../../src/adapter/VeHemiAragonAdapter.sol";
import {VeHemi} from "../../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../../src/VeHemiVoteDelegation.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title FlatBulkDelegationAndExpiryTest
 * @notice Directed tests for three paths no invariant campaign reaches.
 *
 *        test_H1_* `delegateAllFor` x auto-relock, through the REAL Aragon
 *                  adapter (the user-facing `adapter.delegate(X)`). A FLAT
 *                  position's stored `end` is frozen and falls into the past,
 *                  so a liveness test on `end` alone would skip exactly the
 *                  positions the flag keeps alive; every body here consults
 *                  the flag.
 *        test_H2_* the `fixedBias` carry in
 *                  `VeHemiVoteDelegation::calculateExpiredDelegations` (pushed
 *                  verbatim by the permissionless
 *                  `writeNewCheckpointForExpiredDelegations`) and the three
 *                  checked subtractions beside it (`normalizedBias`,
 *                  `normalizedSlope`, `totalAmount`). These bodies build a
 *                  FLAT delegator first, which is what makes `fixedBias`
 *                  non-zero and a dropped carry observable.
 *        test_H3_* the `withdraw` boundary. Both invariant handlers gate their
 *                  withdraw action on `block.timestamp >= end`, which IS the
 *                  predicate under test, so only a directed body that names
 *                  the boundary can check it.
 */
contract FlatBulkDelegationAndExpiryTest is Test {
    MockERC20 hemi;
    VeHemi veHemi;
    VeHemiVoteDelegation delegation;
    VeHemiAragonAdapter adapter;

    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B);
    address constant CAROL = address(0xCA401);
    address constant DAVE  = address(0xDA7E);

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant SIX_DAYS = YEAR / 60;
    uint256 private constant HOUR = 1 hours;

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));
        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);
        adapter = new VeHemiAragonAdapter(address(veHemi));
        delegation.setTrustedAdapter(address(adapter));
        // Start away from t=0 so `end` arithmetic is never degenerate.
        vm.warp(1_700_000_000);
    }

    // ------------------------------------------------------------------ util

    function _lock(address who, uint256 amount, uint256 duration) internal returns (uint256 id) {
        hemi.mint(who, amount);
        vm.startPrank(who);
        hemi.approve(address(veHemi), amount);
        id = veHemi.createLock(amount, duration);
        vm.stopPrank();
    }

    function _enable(address who, uint256 id) internal {
        vm.prank(who);
        veHemi.enableAutoRelock(id);
    }

    function _delegateeOf(uint256 id) internal view returns (address) {
        return delegation.delegation(id).delegatee;
    }

    /// @dev Move to the next hourly checkpoint boundary so a delegation
    ///      written in this epoch becomes live.
    function _crossEpoch() internal {
        vm.warp(((block.timestamp / HOUR) * HOUR) + HOUR);
    }

    // =================================================================== H1

    /// @notice H1-A. A FLAT position whose `end` has fallen into the past is
    ///         delegated by the Aragon bulk flow, not skipped.
    /// @dev    Without the `veHemi.autoRelockRemaining(tokenId) != 0 ||` clause
    ///         of `VeHemiVoteDelegation::delegateAllFor`'s skip guard, only
    ///         `end > checkpointTs` would remain -- which is FALSE here.
    function test_H1_A_flatPastEndIsDelegatedByBulkFlow() public {
        uint256 id = _lock(ALICE, 100e18, 2 * YEAR);
        _enable(ALICE, id);

        // The flag is the liveness predicate; `end` is frozen and falls
        // into the past. Warp well past it and assert BOTH halves of that,
        // so the body cannot silently stop testing what it claims to test.
        vm.warp(block.timestamp + 3 * YEAR);
        veHemi.checkpoint();
        assertGt(veHemi.autoRelockRemaining(id), 0, "fixture: position is not flat");
        assertLt(
            uint256(veHemi.getLockedBalance(id).end),
            block.timestamp,
            "fixture: end is not in the past, the body would be vacuous"
        );

        vm.prank(ALICE);
        adapter.delegate(BOB);

        assertEq(_delegateeOf(id), BOB, "H1: bulk flow SKIPPED a flat position");
        assertEq(adapter.delegates(ALICE), BOB, "H1: adapter.delegates fell to a mixed/zero state");
    }

    /// @notice H1-B. A mixed bag -- one flat, one ordinary live -- moves as one.
    function test_H1_B_mixedBagMovesTogether() public {
        uint256 flatId = _lock(ALICE, 100e18, 2 * YEAR);
        _enable(ALICE, flatId);
        vm.warp(block.timestamp + 3 * YEAR);
        veHemi.checkpoint();
        uint256 liveId = _lock(ALICE, 40e18, YEAR);

        vm.prank(ALICE);
        adapter.delegate(BOB);

        assertEq(_delegateeOf(flatId), BOB, "H1: flat position skipped in a mixed bag");
        assertEq(_delegateeOf(liveId), BOB, "H1: live position skipped in a mixed bag");
        assertEq(adapter.delegates(ALICE), BOB, "H1: post-batch account-wide delegate is not BOB");
    }

    /// @notice H1-C. The WEIGHT moves, not merely the cached delegatee.
    /// @dev    The nearest existing law, `ARLChecks::checkFlatPositionsStayDelegated`
    ///         (run by `invariant_arl_core`), asserts
    ///         `delegation.delegation(id).amount == shadow.amount` -- it
    ///         watches the cached AMOUNT. H1 corrupts the cached DELEGATEE, and
    ///         what a holder actually loses is governance weight, so this body
    ///         asserts on `getVotes` on both sides of the move.
    function test_H1_C_flatWeightMovesBetweenDelegatees() public {
        uint256 id = _lock(ALICE, 100e18, 2 * YEAR);
        _enable(ALICE, id);
        vm.warp(block.timestamp + 3 * YEAR);
        veHemi.checkpoint();

        vm.prank(ALICE);
        adapter.delegate(BOB);
        _crossEpoch();
        uint256 bobVotes = delegation.getVotes(BOB);
        assertGt(bobVotes, 0, "H1: the flat weight never reached BOB");

        vm.prank(ALICE);
        adapter.delegate(CAROL);
        _crossEpoch();
        assertEq(delegation.getVotes(BOB), 0, "H1: weight STRANDED on the old delegatee");
        assertEq(delegation.getVotes(CAROL), bobVotes, "H1: weight did not arrive at the new delegatee");
        assertEq(adapter.delegates(ALICE), CAROL, "H1: adapter view did not follow the move");
    }

    /// @notice H1-D. The deliberate skip, and its documented remediation,
    ///         pinned as CORRECT for the class it was written for.
    /// @dev    An EXPIRED, NON-FLAT position IS skipped, the post-state is
    ///         genuinely mixed, `adapter.delegates()` is `address(0)` and no
    ///         `DelegateChanged` is emitted. That is intended (see
    ///         `VeHemiAragonAdapter::delegate`'s NatSpec). This body pins that the
    ///         escape hatch the source documents -- `VeHemi.withdraw(tokenId)`
    ///         then retry -- actually works for THAT class, which is what makes
    ///         the flat case (H1-E) different in kind rather than in degree.
    function test_H1_D_expiredNonFlatIsSkippedButRemediable() public {
        uint256 flatId = _lock(ALICE, 100e18, 2 * YEAR);
        _enable(ALICE, flatId);
        uint256 shortId = _lock(ALICE, 20e18, 2 * SIX_DAYS);

        vm.prank(ALICE);
        delegation.delegate(shortId, DAVE);
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        veHemi.checkpoint();

        vm.prank(ALICE);
        adapter.delegate(BOB);

        assertEq(_delegateeOf(flatId), BOB, "H1: flat position skipped alongside an expired one");
        assertEq(_delegateeOf(shortId), DAVE, "fixture: the expired position was not skipped");
        assertEq(adapter.delegates(ALICE), address(0), "the mixed post-state must read as address(0)");

        // The documented remediation, executed.
        vm.prank(ALICE);
        veHemi.withdraw(shortId);
        vm.prank(ALICE);
        adapter.delegate(BOB);
        assertEq(adapter.delegates(ALICE), BOB, "documented remediation did not restore the account-wide view");
    }

    /// @notice H1-E. WHY THE FLAG CLAUSE IN `delegateAllFor`'s GUARD MUST
    ///         EXIST: for a FLAT position the documented remediation is CLOSED.
    /// @dev    `VeHemi::withdraw` reverts `LockNotExpired`
    ///         while `autoRelockRemaining != 0`, so a holder whose flat
    ///         position were skipped could not withdraw it, could not
    ///         re-delegate around it, and would have no path back to a uniform
    ///         account-wide delegate short of disabling auto-relock and giving
    ///         up the feature. That asymmetry with H1-D is why the flag clause
    ///         matters.
    function test_H1_E_withdrawRemediationIsClosedWhileFlat() public {
        uint256 id = _lock(ALICE, 100e18, 2 * YEAR);
        _enable(ALICE, id);
        vm.warp(block.timestamp + 3 * YEAR);
        veHemi.checkpoint();
        assertLt(uint256(veHemi.getLockedBalance(id).end), block.timestamp, "fixture: end not in the past");

        vm.prank(ALICE);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(id);
    }

    /// @notice H1-F. `delegateAllFor` is ADAPTER-GATED, not permissionless.
    /// @dev    Pins the access rule: the ONLY route to this function is the
    ///         trusted adapter.
    function test_H1_F_delegateAllForIsAdapterGated() public {
        _lock(ALICE, 100e18, YEAR);
        vm.prank(ALICE);
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        delegation.delegateAllFor(ALICE, BOB);
    }

    // =================================================================== H2

    /// @notice H2. The `fixedBias` carry survives a permissionless expiration
    ///         materialization.
    /// @dev    `writeNewCheckpointForExpiredDelegations` has NO access control,
    ///         and the checkpoint it pushes is a REPLACEMENT for the last one.
    ///         Writing a literal 0 into `fixedBias` there would let ANY address
    ///         destroy a delegatee's entire flat voting aggregate with one call.
    ///         `HemiVoteDelegation.t.sol::testExpirations` checks the other four
    ///         fields, on a fixture with no flat delegator.
    function test_H2_fixedBiasSurvivesPermissionlessExpirationWrite() public {
        // A flat delegator: this is what makes `fixedBias` non-zero.
        uint256 flatId = _lock(ALICE, 100e18, 2 * YEAR);
        _enable(ALICE, flatId);
        vm.prank(ALICE);
        delegation.delegate(flatId, DAVE);

        // A decaying delegator that WILL expire, so there is something to
        // materialize and the function does not return at its idle gate.
        uint256 shortId = _lock(BOB, 50e18, 2 * SIX_DAYS);
        vm.prank(BOB);
        delegation.delegate(shortId, DAVE);

        _crossEpoch();
        uint256 flatWeight = delegation.getVotes(DAVE);
        assertGt(flatWeight, 0, "fixture: DAVE has no votes at all");

        vm.warp(block.timestamp + 3 * SIX_DAYS);
        veHemi.checkpoint();
        uint256 before = delegation.getVotes(DAVE);
        assertGt(before, 0, "fixture: the flat term is not carrying DAVE's votes");

        // The permissionless call, made by a total stranger.
        vm.prank(CAROL);
        delegation.writeNewCheckpointForExpiredDelegations(DAVE);

        assertEq(
            delegation.getVotes(DAVE),
            before,
            "H2: a permissionless expiration write DESTROYED the flat voting aggregate"
        );

        IVeHemiVoteDelegation.DelegateCheckpoint[] memory cps =
            delegation.getDelegationCheckpoints(DAVE);
        assertGt(cps[cps.length - 1].fixedBias, 0, "H2: fixedBias was not carried forward");
    }

    /// @notice H2-B. And `delegate()` still works for that pair afterwards.
    /// @dev    With a zeroed `fixedBias`, the subtractive branch of
    ///         `_calculateCheckpoint` would run `fixedBias -= delta` against it,
    ///         revert `panic 0x11` and brick `delegate()` for that (flat
    ///         delegator, delegatee) pair for ever -- swallowed by
    ///         `VeHemi._delegate`'s try/catch, so the victim gets no error.
    function test_H2_B_delegateStillWorksAfterExpirationWrite() public {
        uint256 flatId = _lock(ALICE, 100e18, 2 * YEAR);
        _enable(ALICE, flatId);
        vm.prank(ALICE);
        delegation.delegate(flatId, DAVE);
        uint256 shortId = _lock(BOB, 50e18, 2 * SIX_DAYS);
        vm.prank(BOB);
        delegation.delegate(shortId, DAVE);
        _crossEpoch();
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        veHemi.checkpoint();

        vm.prank(CAROL);
        delegation.writeNewCheckpointForExpiredDelegations(DAVE);

        // Move the flat term away. With a zeroed carry this would panic inside
        // `_calculateCheckpoint` and strand the record.
        vm.prank(ALICE);
        delegation.delegate(flatId, CAROL);
        assertEq(_delegateeOf(flatId), CAROL, "H2: the flat delegation could not be moved away");
        _crossEpoch();
        assertGt(delegation.getVotes(CAROL), 0, "H2: the flat weight did not arrive at the new delegatee");
    }

    /// @notice H2-C. The three CHECKED subtractions in the same struct literal
    ///         (`normalizedBias`, `normalizedSlope`, `totalAmount`), exercised
    ///         and asserted field by field against an independently computed
    ///         expectation.
    function test_H2_C_expirationNettingIsExactOnAllThreeFields() public {
        uint256 flatId = _lock(ALICE, 100e18, 2 * YEAR);
        _enable(ALICE, flatId);
        vm.prank(ALICE);
        delegation.delegate(flatId, DAVE);
        uint256 shortId = _lock(BOB, 50e18, 2 * SIX_DAYS);
        vm.prank(BOB);
        delegation.delegate(shortId, DAVE);
        _crossEpoch();

        IVeHemiVoteDelegation.DelegateCheckpoint[] memory before =
            delegation.getDelegationCheckpoints(DAVE);
        IVeHemiVoteDelegation.DelegateCheckpoint memory last = before[before.length - 1];

        vm.warp(block.timestamp + 3 * SIX_DAYS);
        veHemi.checkpoint();

        // The public VIEW half. If any of the three underflowed, this call
        // itself would revert `panic 0x11`.
        IVeHemiVoteDelegation.DelegateCheckpoint memory calc =
            delegation.calculateExpiredDelegations(DAVE);

        assertGt(last.fixedBias, 0, "fixture: no flat delegator, the fixedBias assertion below would be vacuous");
        assertGt(last.normalizedBias, 0, "fixture: no decaying delegator, the netting assertions would be vacuous");

        assertGt(calc.timestamp, last.timestamp, "timestamp did not advance");
        assertEq(calc.fixedBias, last.fixedBias, "fixedBias was not carried forward verbatim");

        // ALICE is FLAT: her whole weight rides in `fixedBias`, her DECAYING
        // components are identically zero, and she books NO SIX_DAYS bucket.
        // BOB is the only decaying delegator and his whole contribution has now
        // expired. So `normalizedBias` and `normalizedSlope` must land on
        // EXACTLY zero -- not merely
        // "not larger", which is what an `assertLe` would let a deleted netting
        // slip through.
        assertEq(calc.normalizedBias, 0, "normalizedBias: the expired bias was not netted off");
        assertEq(calc.normalizedSlope, 0, "normalizedSlope: the expired slope was not netted off");

        // `totalAmount` IS ASYMMETRIC WITH THE OTHER TWO, AND THIS PINS IT.
        // `totalAmount` is the ONE field of the three a FLAT delegator moves:
        // the additive branch books `totalAmount += delta_.amount` for a flat
        // contribution as well, while `_moveVotingPowerToNewDelegate` books it
        // no expiration bucket (gated on `fixedBias == 0`). So the flat
        // principal is in `totalAmount` and is never netted off by the bucket
        // walk -- which is why `totalAmount`, alone of the three, could be
        // driven below its bucket sum. The other two have no such path because
        // a flat delta's bias and slope are zero on BOTH sides. Asserted here:
        // the decaying principal nets off to the wei and the flat principal
        // survives untouched.
        assertEq(
            last.totalAmount - calc.totalAmount,
            50e18,
            "totalAmount: the expired DECAYING principal was not netted off exactly"
        );
        assertEq(calc.totalAmount, 100e18, "totalAmount: the FLAT principal did not survive the netting");

        vm.prank(CAROL);
        delegation.writeNewCheckpointForExpiredDelegations(DAVE);
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory after_ =
            delegation.getDelegationCheckpoints(DAVE);
        IVeHemiVoteDelegation.DelegateCheckpoint memory w = after_[after_.length - 1];
        assertEq(w.normalizedBias, calc.normalizedBias, "writer did not push the view's normalizedBias");
        assertEq(w.normalizedSlope, calc.normalizedSlope, "writer did not push the view's normalizedSlope");
        assertEq(w.totalAmount, calc.totalAmount, "writer did not push the view's totalAmount");
        assertEq(w.fixedBias, calc.fixedBias, "writer did not push the view's fixedBias");
    }

    // =================================================================== H3

    /// @notice H3. The withdraw boundary is EXACT.
    /// @dev    Both campaign handlers (`ARLHandler`, `InvariantHandler`) refuse
    ///         to issue a withdraw unless `block.timestamp >= end`, so the state
    ///         `t == end - 1` -- where a guard weakened to
    ///         `block.timestamp + 1 < end` would differ -- is outside their
    ///         reach by construction. A handler whose precondition IS the guard
    ///         cannot test the guard.
    function test_H3_withdrawBoundaryIsExactToOneSecond() public {
        uint256 id = _lock(ALICE, 100e18, YEAR);
        uint256 end = uint256(veHemi.getLockedBalance(id).end);

        vm.warp(end - 1);
        vm.prank(ALICE);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(id);

        vm.warp(end);
        vm.prank(ALICE);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(ALICE), 100e18, "withdraw at exactly `end` did not pay out");
    }

    /// @notice H3-B. The mirror, one bucket out, so the body would also notice
    ///         a constant much larger than one second.
    function test_H3_B_withdrawIsRefusedWellBeforeEnd() public {
        uint256 id = _lock(ALICE, 100e18, YEAR);
        uint256 end = uint256(veHemi.getLockedBalance(id).end);

        vm.warp(end - SIX_DAYS);
        vm.prank(ALICE);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(id);
    }
}
