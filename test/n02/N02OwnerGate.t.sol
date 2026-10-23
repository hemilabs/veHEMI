// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../LockedCurveTestBase.sol";
import {N04VoteContinuityLaw as N04} from "../n04/N04VoteContinuityLaw.sol";

/// THE OWNER GATE ON `increaseAmount`.
///
/// `increaseAmount` is owner-only (`ownerOf`, not approvals or operators). The
/// gate prevents an UNCONSENTED THIRD-PARTY MUTATION: a party with no
/// authority over a position writing to it and moving the delegatee's sealed
/// voting record. Every body reads the delegation surface through `getVotes` /
/// `getPastVotes` only.
///
///   G1-G3, G8   the gate works (stranger, approved address, operator; burned
///               and nonexistent ids). G1-G3 go through
///               `N04VoteContinuityLaw.assertOnlyOwnerCanMutate`, which first
///               proves that the OWNER's identical call does move the
///               delegatee's sealed ledger (against a no-call counterfactual),
///               and only then requires the non-owner's call to revert. A lone
///               "the stranger reverts" assertion would also pass on a call
///               that never reached the ledger.
///   G4, G6      the owner's own top-up and extension open no hole in the
///               delegatee's votes (both legs of a re-delegation land at
///               `block.timestamp + 1`).
///   G7, G9-G11  the gate leaves everything else intact (owner flows,
///               `createLockFor`, ERC-721 approval semantics).
contract N02OwnerGateTest is LockedCurveTestBase {
    address internal constant MALLORY = address(0xBAD0);
    address internal constant MARKET = address(0x4A4E7); // a "marketplace"

    /// The dust amount G1-G3 drive through `N04VoteContinuityLaw`'s clause C4
    /// (`assertOnlyOwnerCanMutate`). A 1-wei top-up leaves the
    /// position's delegation record (bias, slope, end) unchanged, so it does
    /// not move the delegatee's ledger and C4 would (correctly) refuse to
    /// credit a stranger's revert on it. 1 gwei does move it and still costs
    /// a would-be griefer nothing.
    uint256 internal constant C4_DUST = 1 gwei;

    /// Bob's votes one second after the trigger instant for EXACTLY this
    /// scenario (500 HEMI locked for 7*SIX_DAYS, delegated to bob), with no
    /// top-up at all: one second of decay from 14,576,678,834,890,110,120.
    /// Asserting the literal (not a delta, not a tolerance) pins the reading
    /// to the wei.
    uint256 internal constant PRISTINE_AT_T1 = 14_576_674_873_879_133_367;

    function _b(uint256 t) internal pure returns (uint256) {
        return (t / 1 hours) * 1 hours + 1 hours;
    }

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o);
        id = veHemi.createLock(a, d);
    }

    /// @dev A delegated, matured, decaying position: the scenario
    ///      `PRISTINE_AT_T1` was taken on.
    function _armed(uint256 dur) internal returns (uint256 id, uint256 v0) {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        id = _mk(alice, 500 ether, dur);
        vm.prank(alice);
        delegation.delegate(id, bob);
        vm.warp(_b(block.timestamp) + 600);
        v0 = delegation.getVotes(bob);
        assertGt(v0, 0, "precondition: delegatee has votes");
    }

    function _one(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }

    function _fund(address who, uint256 amt) internal {
        hemi.mint(who, amt);
        vm.prank(who);
        hemi.approve(address(veHemi), type(uint256).max);
    }

    // =====================================================================
    // PART 1 -- THE GATE WORKS.
    // =====================================================================

    /// G1. THE HEADLINE. A stranger's DUST top-up (`C4_DUST`) REVERTS, and
    ///     the victim's live and historical weight are UNCHANGED TO THE WEI.
    ///
    ///     Three assertions, in increasing strength:
    ///       (a) the call reverts (C4, after the owner arm proved it mutates);
    ///       (b) at `t+1` bob reads the `PRISTINE_AT_T1` literal;
    ///       (c) across the following hour, and in `getPastVotes` 400 days
    ///           later, bob's readings are IDENTICAL to a no-touch
    ///           counterfactual replayed from a snapshot.
    ///     (c) is the one that cannot be satisfied by accident: it compares
    ///     the contract against ITSELF with the trigger removed, so it needs
    ///     no closed form for the weight and no tolerance.
    function test_N02_G1_strangerDustReverts_victimUnchangedToTheWei() public {
        (uint256 id, uint256 v0) = _armed(7 * SIX_DAYS);
        uint256 T = block.timestamp;
        uint256 N = 120; // 120 samples x 30 s == one full hour

        // --- ARM A: the counterfactual. Nobody touches anything. ---
        uint256 snap = vm.snapshotState();
        uint256[] memory control = new uint256[](N);
        for (uint256 i; i < N; ++i) {
            vm.warp(T + 1 + i * 30);
            control[i] = delegation.getVotes(bob);
        }
        vm.revertToState(snap);

        // --- ARM B: the attack, refused. THE REFUSAL IS ASSERTED BY THE
        //     SHARED LAW, not here: `assertOnlyOwnerCanMutate` runs the OWNER
        //     arm first (proving that this exact call DOES
        //     mutate bob's sealed ledger) and only then requires the stranger
        //     to be turned away.
        //     It restores the snapshot itself, so `block.timestamp` and all
        //     state are unchanged when it returns. ---
        _fund(MALLORY, C4_DUST);
        _fund(alice, C4_DUST);
        N04.assertOnlyOwnerCanMutate(
            delegation,
            address(veHemi),
            abi.encodeWithSignature("increaseAmount(uint256,uint256)", id, C4_DUST),
            MALLORY,
            alice,
            bob,
            _one(id),
            "increaseAmount/stranger"
        );
        assertEq(block.timestamp, T, "arm B must start at the same instant");

        vm.warp(T + 1);
        uint256 atT1 = delegation.getVotes(bob);
        emit log_named_uint("G1 votes before            ", v0);
        emit log_named_uint("G1 votes at t+1 (gated)    ", atT1);
        emit log_named_uint("G1 no-touch literal        ", PRISTINE_AT_T1);
        assertEq(atT1, PRISTINE_AT_T1, "G1: the refused arm must read the no-touch value to the wei");

        uint256 differing;
        for (uint256 i; i < N; ++i) {
            vm.warp(T + 1 + i * 30);
            if (delegation.getVotes(bob) != control[i]) {
                unchecked {
                    ++differing;
                }
            }
        }
        assertEq(differing, 0, "G1: a refused stranger still moved live votes");

        // And the permanent half: `getPastVotes`, sampled a year later.
        vm.warp(T + 400 days);
        uint256 sealedDiffering;
        for (uint256 i; i < N; ++i) {
            if (delegation.getPastVotes(bob, T + 1 + i * 30) != control[i]) {
                unchecked {
                    ++sealedDiffering;
                }
            }
        }
        emit log_named_uint("G1 live samples differing  ", differing);
        emit log_named_uint("G1 SEALED samples differing", sealedDiffering);
        assertEq(sealedDiffering, 0, "G1: the refusal must also leave getPastVotes untouched");
    }

    /// G2. AN ERC-721 *APPROVED* ADDRESS IS ALSO REFUSED.
    ///
    ///     WHY APPROVALS ARE NOT HONOURED. ERC-721 convention treats an
    ///     approved address as authorised for TRANSFERS. A top-up is not
    ///     that kind of act: it moves value IN (irreversibly, to the owner's
    ///     benefit) and it FIRES A RE-DELEGATION that MOVES THE OWNER'S
    ///     DELEGATEE'S SEALED VOTING RECORD, which an approved address was
    ///     never granted.
    ///     Consent to sell an NFT is
    ///     not consent to move the seller's governance weight. Strict `ownerOf`
    ///     also matches the contract's other owner gates
    ///     (`increaseUnlockTime`, `withdraw`, `enableAutoRelock`,
    ///     `disableAutoRelock`, `refreshAutoRelock`), none of which honours
    ///     approvals.
    function test_N02_G2_approvedAddressIsRefused() public {
        (uint256 id, ) = _armed(7 * SIX_DAYS);
        vm.prank(alice);
        veHemi.approve(MALLORY, id);
        assertEq(veHemi.getApproved(id), MALLORY, "precondition: approval is really set");

        _fund(MALLORY, C4_DUST);
        _fund(alice, C4_DUST);
        N04.assertOnlyOwnerCanMutate(
            delegation,
            address(veHemi),
            abi.encodeWithSignature("increaseAmount(uint256,uint256)", id, C4_DUST),
            MALLORY,
            alice,
            bob,
            _one(id),
            "increaseAmount/approved"
        );
    }

    /// G3. AN `isApprovedForAll` OPERATOR IS ALSO REFUSED -- THE LISTED-FOR-
    ///     SALE CASE, THE CASE THE RULE EXISTS FOR.
    ///
    ///     `VeHemi` overrides NEITHER `approve` NOR `setApprovalForAll`, so
    ///     OZ's unrestricted versions apply and blanket operator grants to
    ///     marketplaces already exist in the wild on transferable positions.
    ///     Honouring them here would RETROACTIVELY ARM every one of those
    ///     grants with exactly the dust mutation trigger this gate removes --
    ///     through the most over-granted and least-revoked approval surface
    ///     in NFT-land. That would make the gate close the front door and
    ///     leave the side door open, which is worse than having no gate.
    function test_N02_G3_operatorForAllIsRefused_listedForSale() public {
        (uint256 id, uint256 v0) = _armed(7 * SIX_DAYS);
        vm.prank(alice);
        veHemi.setApprovalForAll(MARKET, true); // alice lists her position
        assertTrue(veHemi.isApprovedForAll(alice, MARKET), "precondition: operator set");

        _fund(MARKET, C4_DUST);
        _fund(alice, C4_DUST);
        N04.assertOnlyOwnerCanMutate(
            delegation,
            address(veHemi),
            abi.encodeWithSignature("increaseAmount(uint256,uint256)", id, C4_DUST),
            MARKET,
            alice,
            bob,
            _one(id),
            "increaseAmount/operatorForAll"
        );

        // Same wei-exact evidence as G1, for the operator path.
        uint256 T = block.timestamp;
        vm.warp(T + 1);
        assertEq(delegation.getVotes(bob), PRISTINE_AT_T1, "G3: operator refusal must leave votes intact");
        vm.warp(T + 400 days);
        assertEq(delegation.getPastVotes(bob, T + 1), PRISTINE_AT_T1, "G3: and intact in history");
        assertGt(v0, 0, "G3: sanity");
    }

    /// G8. A NONEXISTENT OR BURNED ID REVERTS `NotOwner`, NOT
    ///     `NoExistingLock`.
    ///
    ///     `_ownerOf` returns `address(0)` for both, and the gate runs first,
    ///     the same ordering as `increaseUnlockTime`. The selector is
    ///     ABI-observable, so it is pinned here: for these ids an integrator
    ///     must match `NotOwner`, not `NoExistingLock()`.
    function test_N02_G8_nonexistentAndBurnedIdsRevertNotOwner() public {
        vm.prank(MALLORY);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseAmount(999_999, 1);

        // Burned: create, expire, withdraw, then top up.
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 2 * SIX_DAYS);
        vm.warp(veHemi.getLockedBalance(id).end + 1);
        vm.prank(alice);
        veHemi.withdraw(id);

        _fund(alice, 1 ether);
        vm.prank(alice); // even the FORMER owner is refused, correctly
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseAmount(id, 1);
    }

    // =====================================================================
    // PART 2 -- THE OWNER'S OWN WRITES OPEN NO HOLE.
    // =====================================================================

    /// G4. The OWNER's own 1-wei top-up -- which no access control can refuse
    ///     -- leaves bob's votes exactly where a no-touch world has them: the
    ///     `PRISTINE_AT_T1` literal at `t+1`, never zero anywhere up to the
    ///     hour boundary, and the same in `getPastVotes` 400 days later. Bob
    ///     did not act and is not on the call path, so no gate could protect
    ///     him; the dating (`block.timestamp + 1` for both legs of the
    ///     re-delegation) does.
    function test_N02_G4_ownerOwnDustOpensNoHole() public {
        (uint256 id, uint256 v0) = _armed(7 * SIX_DAYS);

        _fund(alice, 1);
        vm.prank(alice);
        veHemi.increaseAmount(id, 1); // an honest, unrefusable, 1-wei top-up

        uint256 T = block.timestamp;
        uint256 bnd = _b(T);
        uint256 width = bnd - (T + 1);

        vm.warp(T + 1);
        uint256 atT1 = delegation.getVotes(bob);
        emit log_named_uint("G4 votes before (bob)      ", v0);
        emit log_named_uint("G4 votes at t+1            ", atT1);
        assertEq(width, 2999, "G4 fixture: the window to the boundary must be 3599 - (t mod 3600)");
        assertEq(atT1, PRISTINE_AT_T1, "G4: the owner's 1 wei moved bob's votes at t+1");

        // No zero reading anywhere up to the boundary...
        uint256 zeroSamples;
        for (uint256 t = T + 1; t < bnd; ++t) {
            vm.warp(t);
            if (delegation.getVotes(bob) == 0) {
                unchecked {
                    ++zeroSamples;
                }
            }
        }
        assertEq(zeroSamples, 0, "G4: the owner's own 1 wei blacked bob out");

        vm.warp(bnd);
        assertGt(delegation.getVotes(bob), 0, "G4: bob has no votes at the boundary");
        // ...and none sealed into history.
        vm.warp(bnd + 400 days);
        assertEq(delegation.getPastVotes(bob, T + 1), PRISTINE_AT_T1, "G4: the sealed reading at t+1 moved");
    }

    /// G6. The other owner write, `increaseUnlockTime` (also owner-only),
    ///     re-books the longer lock to bob from `t+1`:
    ///     his votes RISE at once, to the escrow's own reading of the position.
    function test_N02_G6_ownerExtensionOpensNoHole() public {
        (uint256 id, uint256 v0) = _armed(7 * SIX_DAYS);
        vm.prank(alice);
        veHemi.increaseUnlockTime(id, 20 * SIX_DAYS);
        uint256 T = block.timestamp;
        vm.warp(T + 1);
        uint256 atT1 = delegation.getVotes(bob);
        emit log_named_uint("G6 votes before", v0);
        emit log_named_uint("G6 votes at t+1", atT1);
        assertGt(atT1, v0, "G6: the owner's extension did not raise bob's votes at t+1");
        assertEq(atT1, veHemi.balanceOfNFT(id), "G6: bob's votes at t+1 differ from the escrow's weight");
        vm.warp(T + 400 days);
        assertEq(delegation.getPastVotes(bob, T + 1), atT1, "G6: the sealed reading at t+1 differs");
    }

    // =====================================================================
    // PART 3 -- EVERYTHING ELSE IS INTACT.
    // =====================================================================

    /// G7. PLACEMENT PROOF: the gate is in `increaseAmount`, NOT in
    ///     `_depositFor`.
    ///
    ///     `_depositFor` has exactly three callers: `increaseAmount`,
    ///     `increaseUnlockTime` (gated at its own head) and `_createLock`.
    ///     `createLockFor` mints to `account_` and THEN deposits, so inside
    ///     `_depositFor` the token is owned by `account_`, not by
    ///     `_msgSender()`. A check placed in `_depositFor` would therefore
    ///     revert every third-party mint. `createLockFor` is permissionless
    ///     BY DESIGN and harmless -- it creates a NEW position and cannot
    ///     touch any existing position's delegation. This body pins that
    ///     placement.
    function test_N02_G7_createLockForByAStrangerStillWorks() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        _fund(MALLORY, 500 ether);
        vm.prank(MALLORY);
        uint256 id = veHemi.createLockFor(500 ether, 7 * SIX_DAYS, bob, true, false);
        assertEq(veHemi.ownerOf(id), bob, "G7: the stranger-funded mint must land on bob");
        // The mint self-delegates to `account_` via `_resolveAutoDelegate`.
        vm.warp(_b(block.timestamp) + 1);
        assertGt(delegation.getVotes(bob), 0, "G7: and the mint self-delegates to bob");
    }

    /// G9. THE OWNER'S OWN FLOWS THROUGH THE SHARED BODY ALL WORK, and
    ///     a real top-up REACHES the delegatee (the complement of G4: skipping
    ///     the re-book would also open no hole, while freezing bob's weight).
    function test_N02_G9_ownerFlowsIntact_andBookingStillLands() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 20 * SIX_DAYS);
        vm.prank(alice);
        delegation.delegate(id, bob);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        vm.warp(_b(block.timestamp) + 600);
        uint256 before_ = delegation.getVotes(bob);

        _fund(alice, 50 ether);
        vm.prank(alice);
        veHemi.increaseAmount(id, 50 ether); // owner top-up: allowed
        vm.warp(_b(block.timestamp) + 1);
        uint256 after_ = delegation.getVotes(bob);
        emit log_named_uint("G9 before", before_);
        emit log_named_uint("G9 after ", after_);
        assertGt(after_, before_, "G9: the owner's top-up never reached the delegatee");

        // ...and the other owner-side lifecycle calls succeed too.
        vm.prank(alice);
        veHemi.disableAutoRelock(id);
        vm.prank(alice);
        veHemi.increaseUnlockTime(id, 30 * SIX_DAYS);
        vm.prank(alice);
        delegation.delegate(id, charlie);
    }

    /// G10. A NEW OWNER CAN TOP UP AFTER A TRANSFER -- the gate reads
    ///      `_ownerOf` live, so it follows the token. And the FORMER owner is
    ///      refused, which is the property that makes the gate meaningful on
    ///      a traded position.
    function test_N02_G10_gateFollowsTheTokenAcrossTransfer() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice);
        veHemi.transferFrom(alice, charlie, id);

        _fund(alice, 1);
        vm.prank(alice);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.increaseAmount(id, 1);

        _fund(charlie, 1 ether);
        vm.prank(charlie);
        veHemi.increaseAmount(id, 1 ether);
        assertEq(uint256(uint128(veHemi.getLockedBalance(id).amount)), 501 ether, "G10: new owner's top-up applied");
    }

    /// G11. ERC-721 APPROVAL SEMANTICS ARE OTHERWISE UNCHANGED. The gate
    ///      narrows ONE function; it does not silently make approvals inert.
    ///      An operator can still transfer a transferable position.
    function test_N02_G11_approvalsStillWorkForTransfer() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice);
        veHemi.setApprovalForAll(MARKET, true);
        vm.prank(MARKET);
        veHemi.transferFrom(alice, charlie, id);
        assertEq(veHemi.ownerOf(id), charlie, "G11: operator transfer must work");
    }
}
