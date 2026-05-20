// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title MED8_AddressZeroCleanlinessTest
/// @notice Empirical reproducer for MED-8.
///
/// Hypothesis: after a `forfeit()` call, VeHemi calls `_delegate(tokenId, address(0))`
/// which may cause voting power to accumulate against `address(0)` in
/// VeHemiVoteDelegation. If so, `getVotes(address(0))` / `getPastVotes(address(0), ...)`
/// would return non-zero, indicating leakage.
///
/// If all assertions pass, MED-8 is empirically ADDRESSED.
contract MED8_AddressZeroCleanlinessTest is LockedCurveTestBase {
    uint256 constant LOCK_AMOUNT = 100 ether;
    uint256 constant LOCK_DURATION = 2 * 365 days;

    function _createForfeitable(address account_, uint256 amount_)
        internal
        returns (uint256 tokenId_)
    {
        vm.startPrank(account_);
        hemi.mint(account_, amount_);
        hemi.approve(address(veHemi), type(uint256).max);
        tokenId_ = veHemi.createLockFor(amount_, LOCK_DURATION, account_, false, true);
        vm.stopPrank();
    }

    function test_MED8_AddressZero_NotCredited_After_Forfeit() public {
        // 1. Enable forfeit admin (admin == address(this))
        veHemi.updateForfeitAdmin(admin);

        // 2. Create 3 forfeitable locks
        uint256 tokenAlice = _createForfeitable(alice, LOCK_AMOUNT);
        uint256 tokenBob = _createForfeitable(bob, LOCK_AMOUNT);
        uint256 tokenCarol = _createForfeitable(charlie, LOCK_AMOUNT);

        // Move past creation block so checkpoint history exists
        vm.warp(block.timestamp + 1 hours);

        // Sanity check: positions exist with positive voting power for their owners
        assertGt(delegation.getVotes(alice), 0, "alice should have votes pre-forfeit");
        assertGt(delegation.getVotes(bob), 0, "bob should have votes pre-forfeit");
        assertGt(delegation.getVotes(charlie), 0, "carol should have votes pre-forfeit");

        // Pre-forfeit: address(0) should be clean
        assertEq(delegation.getVotes(address(0)), 0, "address(0) dirty pre-forfeit");

        uint256 preForfeitTs = block.timestamp;

        // 3. Forfeit each
        veHemi.forfeit(tokenAlice);
        veHemi.forfeit(tokenBob);
        veHemi.forfeit(tokenCarol);

        // 4. Post-forfeit assertions on address(0)
        uint256 votesNow = delegation.getVotes(address(0));
        uint256 votesPast = delegation.getPastVotes(address(0), block.timestamp);
        // getPastVotes requires timestamp_ <= block.timestamp; use preForfeitTs which is now in the past.
        uint256 votesAgo = delegation.getPastVotes(address(0), preForfeitTs - 1);

        assertEq(votesNow, 0, "MED-8: getVotes(address(0)) != 0 post-forfeit");
        assertEq(votesPast, 0, "MED-8: getPastVotes(address(0), now) != 0 post-forfeit");
        assertEq(votesAgo, 0, "MED-8: getPastVotes(address(0), past) != 0 post-forfeit");

        // 5. Warp 1 year, re-check
        vm.warp(block.timestamp + 365 days);
        assertEq(delegation.getVotes(address(0)), 0, "MED-8: getVotes(address(0)) != 0 after 1y warp");
        assertEq(
            delegation.getPastVotes(address(0), block.timestamp - 1),
            0,
            "MED-8: getPastVotes(address(0), now-1) != 0 after 1y warp"
        );
    }
}
