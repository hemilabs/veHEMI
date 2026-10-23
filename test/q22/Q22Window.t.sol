// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {VeHemi} from "../../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../../src/VeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Votes never exceed supply at an Aragon-reachable snapshot
///         after an `increaseUnlockTime` in a lock's final hour.
///
///   The near-expiry window opens when `H = hourBoundary(tau) >= end`, i.e.
///   for the last `((end - 1) mod 3600) + 1` seconds of the lock (`end` is on
///   the SIX_DAYS grid, `525,960 mod 3600 = 360`, so 360 s to 3,600 s).
contract Q22WindowTest is Test {
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal del;
    MockERC20 internal hemi;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");

    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant MONTH = YEAR / 12;
    uint256 internal constant SIX_DAYS = MONTH / 5;
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

    function _mk(uint256 dur_) internal returns (uint256 id) {
        hemi.mint(alice, AMT);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), AMT);
        id = veHemi.createLockFor(AMT, dur_, alice, false, false);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    /// @notice Aragon's TokenVoting reads veHEMI at `S = block.timestamp - 1`
    ///   (`snapshotTimepoint`), and Hemi blocks are 12 s apart, so after a
    ///   write at block `tau` the reachable snapshots inside `[tau+1, end)`
    ///   are `S = tau + 12k - 1`. This body samples exactly those instants
    ///   for an extension at the first second of the window.
    function test_Q22_W2_aragonReachableSnapshotsInsideTheWindow() public {
        uint256 id = _mk(9 * SIX_DAYS); // bucket 9 -> window 3,240 s
        uint256 end = veHemi.getLockedBalance(id).end;
        uint256 window = ((end - 1) % 1 hours) + 1;
        uint256 tau = end - window; // the first second of the window
        vm.warp(tau);
        vm.prank(alice);
        veHemi.increaseUnlockTime(id, 60 * SIX_DAYS);
        vm.warp(end + 2 hours);

        uint256 reachable;
        int256 worst;
        // Aragon snapshots: S = t_prop - 1, t_prop a block timestamp on a
        // 12 s grid anchored at `tau` (itself a block timestamp).
        for (uint256 k = 1; tau + 12 * k - 1 < end; ++k) {
            uint256 S = tau + 12 * k - 1;
            int256 d = int256(del.getPastVotes(alice, S)) - int256(del.getPastTotalSupply(S));
            if (d > 0) {
                reachable++;
                if (d > worst) worst = d;
            }
        }
        emit log_named_uint("window (s)", window);
        emit log_named_uint("Aragon-reachable snapshots with votes>supply", reachable);
        emit log_named_int("worst over-count at an Aragon snapshot (wei)", worst);
        assertEq(reachable, 0, "the window is reachable through Aragon at the real cadence");
    }
}
