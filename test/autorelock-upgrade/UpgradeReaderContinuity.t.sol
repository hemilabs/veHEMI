// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockUpgradeForkBase.sol";

/// @title  A sample of VeHemi and vote-delegation readers is continuous across the
///         upgrade block.
/// @notice On a Hemi mainnet fork (skips without HEMI_RPC_URL; fork block from
///         AUTORELOCK_TEST_FORK_BLOCK), reads the supply curves, the weights of
///         16 delegated positions of non-zero weight (the first such id in each
///         sixteenth of the id range; a sixteenth with none near its start is
///         made up from the next), their delegatees' votes and the quorum
///         denominator at the current time and at past timestamps, executes the
///         upgrade batch (both proxy upgrades, the vote-delegation one arming
///         the upgrade-hour window) in the same block, and reads them again. No
///         position has auto-relock enabled yet, so the new implementations
///         must report the forked state unchanged -- except
///         `getPastTotalSupply(t)`, which now reads supply at `t - 1` by
///         design.
contract UpgradeReaderContinuityForkTest is AutoRelockUpgradeForkBase {
    uint256 internal constant SAMPLE_SIZE = 16;
    /// @dev Ids scanned per slice before the sample gives up on it.
    uint256 internal constant SCAN_PER_SLICE = 64;

    struct Snapshot {
        uint256 total;
        uint256 nonTransferable;
        uint256 forfeitable;
        uint256 breakdownTotal;
        uint256 breakdownLocked;
        uint256 breakdownForfeitable;
        uint256 breakdownTransferable;
        uint256[] totalAt;
        uint256[] nonTransferableAt;
        uint256[] forfeitableAt;
        uint256[] weight;
        uint256[] weightAt;
        uint256[] votes;
        uint256[] pastVotes;
    }

    function _times() internal view returns (uint256[4] memory t) {
        t = [block.timestamp, block.timestamp - 1 hours, block.timestamp - 7 days, block.timestamp - 90 days];
    }

    /// @dev The first delegated id of non-zero weight in each of SAMPLE_SIZE
    ///      equal slices of `[1, nextTokenId)`, so early and recent ids are both
    ///      read. A slice with none in its first SCAN_PER_SLICE ids is made up
    ///      from the next slice (at the default fork block, the ninth slice is
    ///      such a gap).
    function _sample() internal view returns (uint256[] memory ids, address[] memory delegatees) {
        uint256 n = veHemi.nextTokenId();
        ids = new uint256[](SAMPLE_SIZE);
        delegatees = new address[](SAMPLE_SIZE);
        uint256 k;
        uint256 slice = (n - 1) / SAMPLE_SIZE;
        require(slice > 0, "sample: fewer ids than samples");
        for (uint256 s = 0; s < SAMPLE_SIZE; ++s) {
            uint256 lo = 1 + s * slice;
            uint256 hi = lo + (slice < SCAN_PER_SLICE ? slice : SCAN_PER_SLICE);
            for (uint256 i = lo; i < hi && k < s + 1; ++i) {
                (address d,,,,) = vvd.delegations(i);
                if (d == address(0) || veHemi.balanceOfNFT(i) == 0) continue;
                ids[k] = i;
                delegatees[k] = d;
                ++k;
            }
        }
        assertEq(k, SAMPLE_SIZE, "sample: not enough delegated positions of non-zero weight near the slice starts");
    }

    function _read(uint256[] memory ids, address[] memory delegatees) internal view returns (Snapshot memory s) {
        uint256[4] memory t = _times();
        s.total = veHemi.totalVeHemiSupply();
        s.nonTransferable = veHemi.nonTransferableTotalVeHemiSupply();
        s.forfeitable = veHemi.forfeitableTotalVeHemiSupply();
        (s.breakdownTotal, s.breakdownLocked, s.breakdownForfeitable, s.breakdownTransferable) = veHemi.supplyBreakdown();
        s.totalAt = new uint256[](t.length);
        s.nonTransferableAt = new uint256[](t.length);
        s.forfeitableAt = new uint256[](t.length);
        for (uint256 j = 0; j < t.length; ++j) {
            s.totalAt[j] = veHemi.totalVeHemiSupplyAt(t[j]);
            s.nonTransferableAt[j] = veHemi.nonTransferableTotalVeHemiSupplyAt(t[j]);
            s.forfeitableAt[j] = veHemi.forfeitableTotalVeHemiSupplyAt(t[j]);
        }
        s.weight = new uint256[](ids.length);
        s.weightAt = new uint256[](ids.length * t.length);
        s.votes = new uint256[](ids.length);
        s.pastVotes = new uint256[](ids.length * (t.length - 1));
        for (uint256 i = 0; i < ids.length; ++i) {
            s.weight[i] = veHemi.balanceOfNFT(ids[i]);
            s.votes[i] = vvd.getVotes(delegatees[i]);
            for (uint256 j = 0; j < t.length; ++j) {
                s.weightAt[i * t.length + j] = veHemi.balanceOfNFTAt(ids[i], t[j]);
                if (j > 0) s.pastVotes[i * (t.length - 1) + j - 1] = vvd.getPastVotes(delegatees[i], t[j]);
            }
        }
    }

    function test_readersAreContinuousAcrossTheBatch() public {
        if (!forkReady) return;
        (uint256[] memory ids, address[] memory delegatees) = _sample();
        uint256[4] memory t = _times();
        Snapshot memory beforeUpgrade = _read(ids, delegatees);
        uint256[4] memory supplyOneSecondEarlier;
        for (uint256 j = 0; j < t.length; ++j) supplyOneSecondEarlier[j] = veHemi.totalVeHemiSupplyAt(t[j] - 1);

        _upgradeBothAndArmWindow();
        Snapshot memory afterUpgrade = _read(ids, delegatees);

        assertEq(afterUpgrade.total, beforeUpgrade.total, "totalVeHemiSupply");
        assertEq(afterUpgrade.nonTransferable, beforeUpgrade.nonTransferable, "nonTransferableTotalVeHemiSupply");
        assertEq(afterUpgrade.forfeitable, beforeUpgrade.forfeitable, "forfeitableTotalVeHemiSupply");
        assertEq(afterUpgrade.breakdownTotal, beforeUpgrade.breakdownTotal, "supplyBreakdown.total");
        assertEq(afterUpgrade.breakdownLocked, beforeUpgrade.breakdownLocked, "supplyBreakdown.locked");
        assertEq(afterUpgrade.breakdownForfeitable, beforeUpgrade.breakdownForfeitable, "supplyBreakdown.forfeitable");
        assertEq(afterUpgrade.breakdownTransferable, beforeUpgrade.breakdownTransferable, "supplyBreakdown.transferable");
        for (uint256 j = 0; j < t.length; ++j) {
            assertEq(afterUpgrade.totalAt[j], beforeUpgrade.totalAt[j], "totalVeHemiSupplyAt");
            assertEq(afterUpgrade.nonTransferableAt[j], beforeUpgrade.nonTransferableAt[j], "nonTransferableTotalVeHemiSupplyAt");
            assertEq(afterUpgrade.forfeitableAt[j], beforeUpgrade.forfeitableAt[j], "forfeitableTotalVeHemiSupplyAt");
            // By design the quorum denominator now reads one second earlier.
            assertEq(vvd.getPastTotalSupply(t[j]), supplyOneSecondEarlier[j], "getPastTotalSupply(t) != supply at t - 1");
        }
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(afterUpgrade.weight[i], beforeUpgrade.weight[i], "balanceOfNFT");
            assertEq(afterUpgrade.votes[i], beforeUpgrade.votes[i], "getVotes");
        }
        for (uint256 k = 0; k < beforeUpgrade.weightAt.length; ++k) assertEq(afterUpgrade.weightAt[k], beforeUpgrade.weightAt[k], "balanceOfNFTAt");
        for (uint256 k = 0; k < beforeUpgrade.pastVotes.length; ++k) assertEq(afterUpgrade.pastVotes[k], beforeUpgrade.pastVotes[k], "getPastVotes");
    }
}
