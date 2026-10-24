// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../../src/VeHemi.sol";
import "../../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/interfaces/IVeHemiVoteDelegation.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockHemiVoteDelegation.sol";

/// @notice A holder written BEFORE the auto-relock upgrade: it knows
///         `transferFrom` and `withdraw`, but has no `disableAutoRelock` path.
///         Disarm-on-transfer is what keeps such a holder from ever holding an
///         armed position it cannot disarm.
contract AutoRelockUnawareHolder {
    function pull(address ve, address from, uint256 id) external {
        VeHemi(ve).transferFrom(from, address(this), id);
    }
    function push(address ve, address to, uint256 id) external {
        VeHemi(ve).transferFrom(address(this), to, id);
    }
    function withdraw(address ve, uint256 id) external {
        VeHemi(ve).withdraw(id);
    }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @notice Who may arm a position, and what a transfer does to an armed one:
///         enable is strict-owner (an ERC-721 approval does not suffice) and
///         needs R >= 2 buckets, the end never moves back and cycling cannot make
///         a position immortal, a transfer disarms with an exact floor-snap (an
///         owner self-transfer does not), an auto-relock-unaware holder
///         receives a disarmed lock, forfeit is not escapable, and
///         `createLockWithAutoRelock` lands in the same state as
///         create-then-enable. Delegation is a mock here.
///         R = `autoRelockRemaining(id)`, the frozen remaining term.
contract AutoRelockAuthzTest is Test {
    MockERC20 hemi;
    VeHemi veHemi;
    MockHemiVoteDelegation mockDelegation;

    address owner = address(0xA11CE);
    address stranger = address(0xBAD);
    address marketplace = address(0x3A2E);
    address buyer = address(0xB0B);
    address forfeitAdmin = address(0xFAFA);

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant SIX_DAYS = YEAR / 60;
    uint256 private constant MAX_TIME = 4 * YEAR;

    function setUp() public {
        vm.warp(1_800_000_000);
        hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(hemi));
        mockDelegation = new MockHemiVoteDelegation();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(mockDelegation)));
        veHemi.updateForfeitAdmin(forfeitAdmin);

        address[5] memory funded = [owner, stranger, marketplace, buyer, address(this)];
        for (uint256 i; i < funded.length; ++i) {
            hemi.mint(funded[i], 1_000_000 ether);
            vm.prank(funded[i]);
            hemi.approve(address(veHemi), type(uint256).max);
        }

        // The seeding guard (`SeedingNotFinalized`) refuses `enableAutoRelock`
        // on subcurve positions until
        // `lockedSeedingFinalized`; flip the latch.
        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
    }

    // ------------------------------------------------------------------ utils
    function _mkTransferable(address to, uint256 amt, uint256 dur) internal returns (uint256 id) {
        vm.prank(to);
        id = veHemi.createLock(amt, dur);
    }

    function _mkNonTransferable(address to, uint256 amt, uint256 dur, bool forfeitable) internal returns (uint256 id) {
        id = veHemi.createLockFor(amt, dur, to, false, forfeitable);
    }

    // =====================================================================
    // A. THE END
    // =====================================================================

    /// `lock.end` keeps its one true meaning. Enable does not move it, and
    /// disable can only move it FORWARD — so `_adjustSlopeChange`'s schedule
    /// guard is never fed a backwards end.
    function test_endNeverMovesBackwards() public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        uint64 end0 = veHemi.getLockedBalance(id).end;
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        assertEq(veHemi.getLockedBalance(id).end, end0, "enable moved end");
        for (uint256 i; i < 8; ++i) {
            vm.warp(block.timestamp + 37 days);
            vm.prank(owner);
            veHemi.disableAutoRelock(id);
            uint64 end1 = veHemi.getLockedBalance(id).end;
            assertGe(end1, end0, "end moved BACKWARDS");
            end0 = end1;
            vm.prank(owner);
            veHemi.enableAutoRelock(id);
        }
    }

    // =====================================================================
    // B. AUTHORIZATION
    // =====================================================================

    function test_enableIsStrictOwner() public {
        uint256 id = _mkTransferable(owner, 100 ether, 200 days);
        vm.prank(stranger);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.enableAutoRelock(id);
    }

    /// THE DANGLING-APPROVAL ATTACK. A marketplace approval is authority to MOVE
    /// the asset, never authority to REDEFINE it. If `enableAutoRelock` honoured
    /// ERC-721 approvals, any dangling marketplace operator could freeze a
    /// victim's principal for as long as it liked, for free.
    function test_approvedOperatorCannotEnable() public {
        uint256 id = _mkTransferable(owner, 100 ether, 200 days);
        vm.prank(owner);
        veHemi.approve(marketplace, id);
        vm.prank(owner);
        veHemi.setApprovalForAll(marketplace, true);

        assertEq(veHemi.getApproved(id), marketplace);
        assertTrue(veHemi.isApprovedForAll(owner, marketplace));

        vm.prank(marketplace);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.enableAutoRelock(id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "operator froze a victim's position");
    }

    /// The enforced floor is R >= 2 * SIX_DAYS (whole buckets from grid(now)),
    /// which makes `floor(now + R) > now` unconditional at disable time. Both
    /// sides of it, at the instant R drops from two buckets to one.
    function test_enableRequiresTwoBuckets() public {
        uint256 id = _mkTransferable(owner, 100 ether, 3 * SIX_DAYS);
        uint256 end = veHemi.getLockedBalance(id).end;
        assertEq(end % SIX_DAYS, 0, "premise: grid-aligned end");

        // Last second at which R == 2 * SIX_DAYS: accepted, with exactly that R.
        uint256 snapshot = vm.snapshotState();
        vm.warp(end - SIX_DAYS - 1);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        assertEq(uint256(veHemi.autoRelockRemaining(id)), 2 * SIX_DAYS, "R == 2 buckets must be accepted");
        vm.revertToState(snapshot);

        // One second later R == SIX_DAYS: refused.
        vm.warp(end - SIX_DAYS);
        vm.prank(owner);
        vm.expectRevert(VeHemi.AutoRelockDurationTooShort.selector);
        veHemi.enableAutoRelock(id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "refused enable armed the position");
    }

    /// Every disable, whenever it is made, lands strictly in the future.
    function testFuzz_disabledEndIsAlwaysFuture(uint64 dt) public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        vm.warp(block.timestamp + (uint256(dt) % (3 * 365 days)));
        vm.prank(owner);
        veHemi.disableAutoRelock(id);
        assertGt(veHemi.getLockedBalance(id).end, block.timestamp, "disable landed in the past");
    }

    /// FLOOR, not ceil / round / bucket-anchor: repeated enable/disable
    /// must never ratchet the unlock time past `now + R`. Ceil makes the
    /// position IMMORTAL.
    function test_noImmortalityUnderCycling() public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        uint256 r0 = veHemi.autoRelockRemaining(id);
        for (uint256 i; i < 30; ++i) {
            vm.warp(block.timestamp + 1 days + 777);
            vm.prank(owner);
            veHemi.disableAutoRelock(id);
            assertLe(
                veHemi.getLockedBalance(id).end,
                block.timestamp + r0,
                "unlock time ratcheted past now + the first enable's R (immortal position)"
            );
            vm.prank(owner);
            veHemi.enableAutoRelock(id);
            assertLe(veHemi.autoRelockRemaining(id), r0, "R grew across a cycle");
        }
    }

    /// A transfer of an armed position whose stored end is in the past is not
    /// an early exit: the disarm restores a live end, so the buyer cannot
    /// withdraw and the weight is not annihilated.
    function test_transferIsNotAFreeEarlyExit() public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        vm.warp(block.timestamp + 500 days); // the stored end is in the past
        vm.prank(owner);
        veHemi.transferFrom(owner, buyer, id);
        uint256 balBefore = hemi.balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(buyer), balBefore, "principal escaped through a transfer");
        assertGt(veHemi.balanceOfNFT(id), 0, "transfer annihilated the weight");
    }

    // =====================================================================
    // C. TRANSFER SEMANTICS
    // =====================================================================

    /// DISARM-ON-TRANSFER. A transfer auto-disables: the flag does not survive
    /// it, so nobody can be left holding a position armed without their consent,
    /// and the end is snapped exactly as `disableAutoRelock` would snap it.
    function test_flagIsClearedOnTransfer() public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        uint64 r = veHemi.autoRelockRemaining(id);

        vm.warp(block.timestamp + 500 days); // the stored end is now in the PAST
        assertLt(veHemi.getLockedBalance(id).end, block.timestamp, "premise: stored end not past");

        vm.prank(owner);
        veHemi.transferFrom(owner, buyer, id);

        assertEq(veHemi.ownerOf(id), buyer);
        // The flag was cleared by the transfer's auto-disable.
        assertEq(veHemi.autoRelockRemaining(id), 0, "flag should have been cleared on transfer");
        // The disarm snapped the end to grid(now)+R, exactly as disableAutoRelock
        // would, so the buyer receives a LIVE decaying lock, not one whose stored
        // end is past.
        assertEq(
            veHemi.getLockedBalance(id).end,
            ((block.timestamp / SIX_DAYS) + uint256(r) / SIX_DAYS) * SIX_DAYS,
            "disarm floor-snap"
        );
        assertGt(veHemi.getLockedBalance(id).end, block.timestamp, "disarmed lock must be live");
        // It is already disarmed, so disableAutoRelock now reverts for everyone.
        vm.prank(buyer);
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        veHemi.disableAutoRelock(id);
    }

    /// THE INTEGRATOR HAZARD. `getLockedBalance().end` is a PAST timestamp on a
    /// live flat position — a marketplace or lending market that prices off it
    /// concludes "expired, withdrawable now" and is wrong. `effectiveLockEnd` is
    /// the number to read, and `isAutoRelockEnabled` the flag that says so.
    function test_storedEndIsTheIntegratorHazard() public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        uint64 r = veHemi.autoRelockRemaining(id);
        vm.warp(block.timestamp + 500 days);

        // What a naive integrator sees:
        assertLt(veHemi.getLockedBalance(id).end, block.timestamp);
        // What is actually true:
        assertTrue((veHemi.autoRelockRemaining(id) != 0));
        assertEq(veHemi.effectiveLockEnd(id), ((block.timestamp + r) / SIX_DAYS) * SIX_DAYS);
        assertGt(veHemi.effectiveLockEnd(id), block.timestamp + 380 days);
        emit log_named_uint("stored end (naive)", veHemi.getLockedBalance(id).end);
        emit log_named_uint("effective end (true)", veHemi.effectiveLockEnd(id));
    }

    /// A position can never arrive ARMED inside a contract that has no disable
    /// path: the pull auto-disables it, so it is a plain decaying lock that
    /// expires and is withdrawable normally.
    function test_flatPositionArrivesDisarmedInAutoRelockUnawareHolder() public {
        AutoRelockUnawareHolder holder = new AutoRelockUnawareHolder();
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        vm.prank(owner);
        veHemi.approve(address(holder), id);
        holder.pull(address(veHemi), owner, id);
        assertEq(veHemi.ownerOf(id), address(holder));
        // The pull disarmed it: it is a live decaying lock, not an armed (flat) position.
        assertEq(veHemi.autoRelockRemaining(id), 0, "arrived armed in an auto-relock-unaware holder");
        assertGt(veHemi.getLockedBalance(id).end, block.timestamp, "disarmed lock must be live");

        // Before its term expires, withdraw is correctly refused.
        vm.expectRevert(VeHemi.LockNotExpired.selector);
        holder.withdraw(address(veHemi), id);

        // After the decaying term expires, the holder withdraws it normally --
        // no push-back-out-and-disable dance is needed.
        uint256 balBefore = hemi.balanceOf(address(holder));
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1);
        holder.withdraw(address(veHemi), id);
        assertEq(hemi.balanceOf(address(holder)), balBefore + 100 ether, "principal not recovered after expiry");
    }

    /// Non-transferable positions (97.96% of live supply) cannot be moved at
    /// all until `transferableAfter`, and auto-relock does not move that date.
    function test_autoRelockDoesNotMoveTransferability() public {
        uint256 id = _mkNonTransferable(owner, 100 ether, 400 days, false);
        uint256 transferableAfter = veHemi.transferableAfter(id);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        assertEq(veHemi.transferableAfter(id), transferableAfter, "auto-relock moved transferableAfter");
        assertFalse(veHemi.isTransferable(id));
        vm.warp(transferableAfter);
        assertTrue(veHemi.isTransferable(id), "flat position never becomes transferable");
    }

    /// `safeTransferFrom` routes through the public virtual `transferFrom`
    /// (OZ v5 ERC721Upgradeable), so the override — and therefore the
    /// `isTransferable` gate and the disarm — are NOT bypassable.
    function test_safeTransferFromUsesTheOverride() public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        vm.prank(owner);
        veHemi.safeTransferFrom(owner, buyer, id);
        assertEq(veHemi.ownerOf(id), buyer);
        assertEq(veHemi.autoRelockRemaining(id), 0, "flag should have been cleared through safeTransferFrom");

        uint256 nonTransferableId = _mkNonTransferable(owner, 100 ether, 400 days, false);
        vm.prank(owner);
        vm.expectRevert(VeHemi.NotTransferable.selector);
        veHemi.safeTransferFrom(owner, buyer, nonTransferableId);
    }

    /// The operator three-hop (victim -> operator, arm, operator -> victim)
    /// would hand the victim back a position armed without their consent.
    /// Disarm-on-transfer closes it: the return leg auto-disables.
    function test_threeHopCannotLeaveTheVictimArmed() public {
        address operator = makeAddr("operator");
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);

        // The victim grants the operator approval (hop 1's precondition).
        vm.prank(owner);
        veHemi.setApprovalForAll(operator, true);

        // hop 1: operator pulls the (not-yet-armed) position to itself.
        vm.prank(operator);
        veHemi.transferFrom(owner, operator, id);
        assertEq(veHemi.ownerOf(id), operator, "hop 1 failed");

        // hop 2: operator arms it (it owns it now).
        vm.prank(operator);
        veHemi.enableAutoRelock(id);
        assertTrue(veHemi.autoRelockRemaining(id) != 0, "premise: not armed mid-hop");

        // hop 3: operator transfers it back to the victim.
        vm.prank(operator);
        veHemi.transferFrom(operator, owner, id);

        // The victim receives a DISARMED, live decaying lock.
        assertEq(veHemi.ownerOf(id), owner, "hop 3 failed");
        assertEq(veHemi.autoRelockRemaining(id), 0, "victim was left holding an ARMED position");
        assertGt(veHemi.getLockedBalance(id).end, block.timestamp, "disarmed lock must be live");
        // Well-formed after disarm: principal intact and weight not destroyed.
        assertEq(int256(veHemi.getLockedBalance(id).amount), int256(uint256(100 ether)), "three-hop changed the principal");
        assertGt(veHemi.balanceOfNFT(id), 0, "disarmed lock lost its weight");
    }

    /// SELF-TRANSFER EXEMPTION. An owner's own self-transfer of an ARMED
    /// position does NOT disarm it (`from_ == to_` changes no ownership). The
    /// benign self-transfer (re-apply auto-delegate) keeps the position armed.
    function test_ownerSelfTransferOfArmedStaysArmed() public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        uint64 r = veHemi.autoRelockRemaining(id);
        assertTrue(r != 0, "premise: not armed");
        uint64 end0 = veHemi.getLockedBalance(id).end;
        int256 amount0 = int256(veHemi.getLockedBalance(id).amount);

        // Warp into a later bucket first, so that without the exemption the
        // disarm would snap end to grid(now)+R != end0.
        vm.warp(block.timestamp + SIX_DAYS - 1);

        vm.prank(owner);
        veHemi.transferFrom(owner, owner, id); // benign self-transfer

        // Stays armed: same R, same end (NO disarm floor-snap even after the warp),
        // owner and principal unchanged, still a flat position carrying weight.
        assertEq(veHemi.ownerOf(id), owner, "self-transfer changed owner");
        assertEq(veHemi.autoRelockRemaining(id), r, "self-transfer disarmed the position");
        assertEq(veHemi.getLockedBalance(id).end, end0, "self-transfer moved the end (exemption gone?)");
        assertEq(int256(veHemi.getLockedBalance(id).amount), amount0, "self-transfer changed the principal");
        assertGt(veHemi.balanceOfNFT(id), 0, "armed position lost its weight");
        // The owner can still disable it normally afterwards.
        vm.prank(owner);
        veHemi.disableAutoRelock(id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "disable after self-transfer failed");
    }

    // =====================================================================
    // D. LIVENESS GUARDS
    // =====================================================================

    /// The owner's `increaseAmount` must not be blocked by a past stored
    /// end, or an owner can no longer top up their own flat position.
    function test_increaseAmountWorksOnFlatPositionWithPastStoredEnd() public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        vm.warp(block.timestamp + 500 days);
        uint256 wBefore = veHemi.balanceOfNFT(id);
        vm.prank(owner);
        veHemi.increaseAmount(id, 100 ether);
        assertGt(veHemi.balanceOfNFT(id), wBefore, "top-up added no weight");
        // Proportional up to the integer truncation in slope = amount/MAX_TIME.
        assertApproxEqRel(veHemi.balanceOfNFT(id), wBefore * 2, 1e12, "top-up not proportional to R");
    }

    /// Auto-relock is NOT an escape from forfeiture. The forfeit window is
    /// `[0, transferableAfter)` and auto-relock cannot move `transferableAfter`.
    function test_autoRelockCannotEscapeForfeit() public {
        uint256 id = _mkNonTransferable(owner, 100 ether, 400 days, true);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        vm.warp(block.timestamp + 100 days);
        uint256 adminBefore = hemi.balanceOf(forfeitAdmin);
        vm.prank(forfeitAdmin);
        veHemi.forfeit(id);
        assertEq(hemi.balanceOf(forfeitAdmin) - adminBefore, 100 ether, "forfeit was defeated");
        assertEq(veHemi.autoRelockRemaining(id), 0, "flag survived the burn");
    }

    /// An armed transfer after the stored end has passed: the transfer disarms
    /// the position before the ownership change (restoring a live end) and
    /// re-delegates it, so the delegation record names the buyer.
    function test_armedTransferWithPastStoredEndRebooksAtTheBuyer() public {
        uint256 id = _mkTransferable(owner, 100 ether, 400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        vm.warp(block.timestamp + 500 days);
        vm.prank(owner);
        veHemi.transferFrom(owner, buyer, id);
        (address delegatee, , , , ) = mockDelegation.delegations(id);
        assertEq(delegatee, buyer, "the armed transfer did not rebook the delegation at the buyer");
    }

    // =====================================================================
    // E. ARM-AT-CREATION (createLockWithAutoRelock)
    // =====================================================================

    /// `createLockWithAutoRelock` must produce a position BYTE-FOR-BYTE
    /// equivalent to create-then-enable in the same block: same flag, same
    /// refresh stamp, same locked balance, same (flat) weight. This is the core
    /// correctness claim — it reuses `_enableAutoRelock`, so it must land in
    /// exactly the state the two-tx path lands in.
    function test_armAtCreationEqualsCreateThenEnable() public {
        uint256 amt = 100 ether;
        uint256 dur = 200 days;

        // Armed at creation, one tx.
        vm.prank(owner);
        uint256 armedAtCreationId = veHemi.createLockWithAutoRelock(amt, dur, true, false);

        // Created plain, then enabled by the owner — SAME block.
        uint256 enabledAfterCreateId = veHemi.createLockFor(amt, dur, owner, true, false);
        assertEq(veHemi.autoRelockRemaining(enabledAfterCreateId), 0, "the plain position armed before enable");
        vm.prank(owner);
        veHemi.enableAutoRelock(enabledAfterCreateId);

        assertEq(
            veHemi.autoRelockRemaining(armedAtCreationId),
            veHemi.autoRelockRemaining(enabledAfterCreateId),
            "R mismatch"
        );
        assertGt(veHemi.autoRelockRemaining(armedAtCreationId), 0, "the armed-at-creation position is not armed");
        assertEq(
            uint256(veHemi.autoRelockRefreshedAt(armedAtCreationId)),
            uint256(veHemi.autoRelockRefreshedAt(enabledAfterCreateId)),
            "refresh stamp mismatch"
        );
        assertEq(
            uint256(veHemi.autoRelockRefreshedAt(armedAtCreationId)),
            block.timestamp,
            "the armed-at-creation refresh stamp is not the creation block"
        );
        assertEq(
            veHemi.getLockedBalance(armedAtCreationId).end,
            veHemi.getLockedBalance(enabledAfterCreateId).end,
            "end mismatch"
        );
        assertEq(
            uint256(uint128(veHemi.getLockedBalance(armedAtCreationId).amount)),
            uint256(uint128(veHemi.getLockedBalance(enabledAfterCreateId).amount)),
            "amount mismatch"
        );
        // Flat weight: the two positions carry identical balance, and it is > 0.
        assertEq(
            veHemi.balanceOfNFT(armedAtCreationId), veHemi.balanceOfNFT(enabledAfterCreateId), "weight mismatch"
        );
        assertGt(veHemi.balanceOfNFT(armedAtCreationId), 0, "zero weight");
    }

    /// Flatness proof: an armed-at-creation position does NOT decay across a
    /// bucket, whereas its unarmed twin does. Distinguishes "really armed
    /// flat" from "merely has a non-zero flag".
    function test_armAtCreationHoldsWeightFlat() public {
        uint256 amt = 100 ether;
        uint256 dur = 200 days;
        vm.prank(owner);
        uint256 armedId = veHemi.createLockWithAutoRelock(amt, dur, true, false);
        uint256 plainId = veHemi.createLockFor(amt, dur, owner, true, false);

        uint256 armedWeightBefore = veHemi.balanceOfNFT(armedId);
        uint256 plainWeightBefore = veHemi.balanceOfNFT(plainId);

        vm.warp(block.timestamp + SIX_DAYS);

        assertEq(veHemi.balanceOfNFT(armedId), armedWeightBefore, "armed position decayed");
        assertLt(veHemi.balanceOfNFT(plainId), plainWeightBefore, "plain position did not decay");
    }

    /// The UNARMED creation paths are untouched by arm-at-creation: both
    /// `createLock` and `createLockFor` create an unarmed, decaying position
    /// (`_createLock` is reached with `autoRelock_ == false`).
    function test_unarmedCreatePathsLeavePositionUnarmed() public {
        uint256 id = veHemi.createLockFor(100 ether, 200 days, owner, true, false);
        assertEq(veHemi.autoRelockRemaining(id), 0, "createLockFor armed the position");
        assertEq(uint256(veHemi.autoRelockRefreshedAt(id)), 0, "createLockFor set a refresh stamp");
        vm.prank(owner);
        uint256 id2 = veHemi.createLock(100 ether, 200 days);
        assertEq(veHemi.autoRelockRemaining(id2), 0, "createLock armed the position");
        assertEq(uint256(veHemi.autoRelockRefreshedAt(id2)), 0, "createLock set a refresh stamp");
    }

    /// Arm-at-creation works for a NON-TRANSFERABLE position post-seeding, and
    /// the owner can still disarm it through the normal path afterwards.
    function test_armAtCreationNonTransferableThenDisable() public {
        vm.prank(owner);
        uint256 id = veHemi.createLockWithAutoRelock(100 ether, 200 days, false, false);
        assertGt(veHemi.autoRelockRemaining(id), 0, "non-transferable not armed");
        vm.prank(owner);
        veHemi.disableAutoRelock(id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "disable failed after arm-at-creation");
    }

    /// Arm-at-creation is SELF-SERVICE only. The armed creator
    /// always mints to `msg.sender`, so no caller can arm a position owned by
    /// someone else (the two-tx path would revert NotOwner at enableAutoRelock).
    /// Minting for a third party stays possible, but only UNARMED.
    function test_armAtCreationAlwaysMintsToCaller() public {
        vm.prank(stranger);
        uint256 id = veHemi.createLockWithAutoRelock(100 ether, 200 days, true, false);
        assertEq(veHemi.ownerOf(id), stranger, "armed lock must be owned by the caller");
        assertGt(veHemi.autoRelockRemaining(id), 0, "not armed");
        assertEq(veHemi.provider(id), stranger, "provider must be the caller");

        // a mint FOR someone else is still possible, but never armed
        vm.prank(stranger);
        uint256 gift = veHemi.createLockFor(100 ether, 200 days, owner, true, false);
        assertEq(veHemi.ownerOf(gift), owner, "mint-for-other should still work");
        assertEq(veHemi.autoRelockRemaining(gift), 0, "a mint for someone else must not be armed");
    }

    /// Arm-at-creation re-applies the seeding guard (SeedingNotFinalized).
    /// In the PRE-seeding window a non-transferable position can be minted, but
    /// arming it at creation must revert exactly as enableAutoRelock would,
    /// so the create path is not an unguarded arming admit-path into seedBatch.
    function test_armAtCreationRespectsSeedingGuard() public {
        // Fresh proxy that is NOT seeding-finalized (unlike the suite's setUp).
        VeHemi logic = new VeHemi(address(hemi));
        MockHemiVoteDelegation delegation = new MockHemiVoteDelegation();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        VeHemi ve = VeHemi(address(proxy));
        ve.updateVoteDelegation(IVeHemiVoteDelegation(address(delegation)));
        hemi.approve(address(ve), type(uint256).max);
        // seedingStarted == false, lockedSeedingFinalized == false here.

        // Non-transferable + armed at creation -> must revert SeedingNotFinalized
        // (mirrors enableAutoRelock's seeding guard), NOT succeed.
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        ve.createLockWithAutoRelock(100 ether, 200 days, false, false);

        // Control: a TRANSFERABLE position (transferableAfter == 0) is NOT a
        // subcurve member, so the seeding guard permits arming it even
        // pre-finalization.
        uint256 transferableId = ve.createLockWithAutoRelock(100 ether, 200 days, true, false);
        assertGt(ve.autoRelockRemaining(transferableId), 0, "transferable arm should be allowed pre-seeding");

        // And the non-transferable position can still be minted UNARMED.
        uint256 nonTransferableId = ve.createLockFor(100 ether, 200 days, address(this), false, false);
        assertEq(ve.autoRelockRemaining(nonTransferableId), 0, "unarmed non-transferable mint should work");
    }
}
