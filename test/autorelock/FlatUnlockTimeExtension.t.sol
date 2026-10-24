// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import "../LockedCurveTestBase.sol";

/// @notice `increaseUnlockTime` on a FLAT position folds the extension into R
///         (whole buckets from `grid(now)`), lifts the flat level to
///         `slope * (R - SIX_DAYS/2)`, and the extension survives a disable.
contract FlatUnlockTimeExtensionTest is LockedCurveTestBase {
    function test_increaseUnlockTimeOnFlatFoldsIntoR() public {
        runSeedingFlow();
        (uint256 id,, uint256 end0) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);
        uint256 gridNow = (block.timestamp / SIX_DAYS) * SIX_DAYS;
        uint64 r0 = veHemi.autoRelockRemaining(id);
        assertEq(uint256(r0), end0 - gridNow, "precondition: R is the whole-bucket remainder");

        uint256 dur = 4 * 365 days - 1 days;
        uint256 newEnd = ((block.timestamp + dur) / SIX_DAYS) * SIX_DAYS;
        vm.prank(alice);
        veHemi.increaseUnlockTime(id, dur);

        uint256 slope = 100 ether / MAX_TIME;
        uint256 r1 = veHemi.autoRelockRemaining(id);
        assertEq(r1, newEnd - gridNow, "increaseUnlockTime did not fold the extension into R");
        assertGt(r1, r0, "R did not grow");
        assertEq(veHemi.balanceOfNFT(id), slope * (r1 - SIX_DAYS / 2), "flat level is not slope * (R - S/2)");

        // ...and it survives a disable: the restored end is grid(now) + R.
        vm.prank(alice);
        veHemi.disableAutoRelock(id);
        assertEq(veHemi.getLockedBalance(id).end, newEnd, "extension lost on disable");
        assertGt(newEnd, end0, "extension did not move the end");
    }
}
