// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

// Auto-relock and the seeding window. While seeding is not finalized,
// `enableAutoRelock` refuses a position whose `transferableAfter` is in the
// future (`SeedingNotFinalized`), and `retireStaleAutoRelock` (permissionless)
// carries no seeding guard. These bodies show that combination is safe:
//
//   S1  a subcurve-enrolled (non-transferable) position can never be flat
//       inside an open window, so the retire cannot reach the class the
//       window accounts for.
//   S2  the window is one-way (a second `markSeedingStarted` reverts), so a
//       position armed after finalization never finds itself inside a window.
//   S3  a transferable flat position retired by a stranger mid-window leaves
//       the subcurve member untouched, the totals reconcile, and
//       `finalizeSeeding` still lands.

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/VeHemiVoteDelegation.sol";
import "../src/interfaces/IVeHemiVoteDelegation.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";

contract AutoRelockSeedingWindowTest is Test {
    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant SIX_DAYS = YEAR / 60;

    MockERC20 internal hemi;
    VeHemi internal ve;
    VeHemiVoteDelegation internal del;
    address internal constant BOB = address(0xB0B);
    address internal constant KEEPER = address(0xCAFE);

    function setUp() public {
        vm.roll(1_000_000);
        vm.warp(2_000 * SIX_DAYS);
        hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        ve = VeHemi(address(proxy));
        del = new VeHemiVoteDelegation(address(ve));
        ve.updateVoteDelegation(IVeHemiVoteDelegation(address(del)));
    }

    function _mint(address who, uint256 amt, uint256 buckets) internal returns (uint256 id) {
        hemi.mint(who, amt);
        vm.startPrank(who);
        hemi.approve(address(ve), type(uint256).max);
        id = ve.createLock(amt, buckets * SIX_DAYS);
        vm.stopPrank();
    }

    /// @notice S1. Subcurve members cannot be made flat while the window is
    ///         open, so the permissionless retire cannot reach them.
    function test_S1_subcurve_members_cannot_be_flat_during_the_window() public {
        hemi.mint(BOB, 1000 ether);
        vm.startPrank(BOB);
        hemi.approve(address(ve), type(uint256).max);
        uint256 nt = ve.createLockFor(1000 ether, 6 * SIX_DAYS, BOB, false, false); // NON-transferable
        vm.stopPrank();
        ve.markSeedingStarted();                       // window OPEN
        assertTrue(ve.seedingStarted(), "window did not open");
        assertFalse(ve.lockedSeedingFinalized(), "window already finalized");
        assertGt(ve.transferableAfter(nt), block.timestamp, "position is not subcurve-enrolled");

        vm.prank(BOB);
        vm.expectRevert(VeHemi.SeedingNotFinalized.selector);
        ve.enableAutoRelock(nt);
        assertEq(uint256(ve.autoRelockRemaining(nt)), 0, "a subcurve member went flat during the window");
        assertEq(uint256(ve.autoRelockRefreshedAt(nt)), 0, "a STAMP exists on a subcurve member");

        // and the retire is not a back door: with no flat term the view itself
        // refuses, so the entry point is unreachable on this position.
        vm.prank(KEEPER);
        vm.expectRevert(VeHemi.AutoRelockNotEnabled.selector);
        ve.retireStaleAutoRelock(nt);
    }

    /// @notice S3. A transferable flat position (the seeding gate lets it
    ///         through, by design) retired by a stranger while the window is
    ///         open. The seeding accumulator only enrolls subcurve members, the
    ///         retire touches none of them, the totals reconcile, and
    ///         `finalizeSeeding` still lands.
    function test_S3_a_stranger_may_retire_a_transferable_flat_position_midwindow() public {
        uint256 tr = _mint(BOB, 1000 ether, 6);             // transferable
        hemi.mint(BOB, 500 ether);
        vm.startPrank(BOB);
        uint256 nt = ve.createLockFor(500 ether, 8 * SIX_DAYS, BOB, false, false); // subcurve member
        vm.stopPrank();

        vm.prank(BOB);
        ve.enableAutoRelock(tr);                            // flat BEFORE the window
        assertGt(uint256(ve.autoRelockRefreshedAt(tr)), 0, "not flat");

        ve.markSeedingStarted();                            // window OPEN, flat position live
        uint256 open = ve.autoRelockStaleAt(tr);
        vm.warp(open); vm.roll(block.number + 1);

        uint256 ntWeightBefore = ve.balanceOfNFT(nt);
        vm.prank(KEEPER);
        ve.retireStaleAutoRelock(tr);                       // A STRANGER, MID-WINDOW
        assertEq(uint256(ve.autoRelockRemaining(tr)), 0, "retire did not execute");
        assertEq(uint256(ve.autoRelockRefreshedAt(tr)), 0, "stamp survived");
        assertEq(ve.balanceOfNFT(nt), ntWeightBefore, "the retire moved a SUBCURVE MEMBER's weight");

        // the window still completes, and the subcurve totals it publishes are
        // the ones the untouched member owns.
        ve.seedBatch(type(uint256).max);
        ve.finalizeSeeding();
        assertTrue(ve.lockedSeedingFinalized(), "finalizeSeeding did not land after a mid-window retire");
        assertEq(ve.nonTransferableTotalVeHemiSupply(), ve.balanceOfNFT(nt),
            "the non-transferable subcurve total is not the one surviving member");
        assertEq(ve.totalVeHemiSupply(), ve.balanceOfNFT(nt) + ve.balanceOfNFT(tr),
            "global supply != sum of the two positions after a mid-window retire");
    }

    /// @notice S2. The window is one-way. Once finalized it cannot be reopened,
    ///         so a flat position created afterwards can never find itself
    ///         inside an open window.
    function test_S2_the_window_cannot_be_reopened_under_a_flat_position() public {
        uint256 id = _mint(BOB, 1000 ether, 6);
        ve.markSeedingStarted();
        ve.seedBatch(type(uint256).max);
        ve.finalizeSeeding();
        assertTrue(ve.lockedSeedingFinalized(), "not finalized");

        vm.prank(BOB);
        ve.enableAutoRelock(id);
        assertGt(uint256(ve.autoRelockRefreshedAt(id)), 0, "stamp not written");

        // the latch refuses a second window
        vm.expectRevert();
        ve.markSeedingStarted();
        assertTrue(ve.lockedSeedingFinalized(), "finalization was cleared");

        // and the retire behaves exactly as it does outside any window
        uint256 open = ve.autoRelockStaleAt(id);
        vm.warp(open - 1); vm.roll(block.number + 1);
        vm.prank(KEEPER);
        vm.expectRevert(VeHemi.AutoRelockNotStale.selector);
        ve.retireStaleAutoRelock(id);
        vm.warp(open); vm.roll(block.number + 1);
        vm.prank(KEEPER);
        ve.retireStaleAutoRelock(id);
        assertEq(uint256(ve.autoRelockRemaining(id)), 0, "retire did not execute");
        assertEq(uint256(ve.autoRelockRefreshedAt(id)), 0, "stamp survived");
    }
}
