// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./R31Base.sol";

/// @title  A sample of VeHemi and vote-delegation readers is continuous across the
///         upgrade block.
/// @notice On a Hemi mainnet fork (skips without HEMI_RPC_URL; pinned by
///         R31_FORK_BLOCK), reads the supply curves, the weights of 16 live
///         delegated positions (the first live delegated id in each sixteenth
///         of the id range; a sixteenth with none near its start is made up
///         from the next), their delegatees' votes and the quorum denominator
///         at the current time and at past timestamps, executes the upgrade
///         batch (both proxy upgrades, the vote-delegation one arming the
///         upgrade-hour window) in the same block, and reads them again. No
///         position is armed with auto-relock yet, so the new implementations
///         must report the live state unchanged -- except
///         `getPastTotalSupply(t)`, which now reads supply at `t - 1` by
///         design.
contract R31SupplyContinuityTest is R31Base {
    uint256 internal constant SAMPLE = 16;
    /// @dev Ids scanned per slice before the sample gives up on it.
    uint256 internal constant SCAN_PER_SLICE = 64;

    struct Snapshot {
        uint256 total;
        uint256 nonTransferable;
        uint256 forfeitable;
        uint256 bdTotal;
        uint256 bdLocked;
        uint256 bdForfeitable;
        uint256 bdTransferable;
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

    /// @dev The first live delegated id in each of SAMPLE equal slices of
    ///      `[1, nextTokenId)`, so early and recent ids are both read. A slice
    ///      with none in its first SCAN_PER_SLICE ids is made up from the next
    ///      slice (at the pin, the ninth slice is such a gap).
    function _sample() internal view returns (uint256[] memory ids, address[] memory dels) {
        uint256 n = veHemi.nextTokenId();
        ids = new uint256[](SAMPLE);
        dels = new address[](SAMPLE);
        uint256 k;
        uint256 slice = (n - 1) / SAMPLE;
        require(slice > 0, "probe: fewer ids than samples");
        for (uint256 s = 0; s < SAMPLE; ++s) {
            uint256 lo = 1 + s * slice;
            uint256 hi = lo + (slice < SCAN_PER_SLICE ? slice : SCAN_PER_SLICE);
            for (uint256 i = lo; i < hi && k < s + 1; ++i) {
                (address d,,,,) = vvd.delegations(i);
                if (d == address(0) || veHemi.balanceOfNFT(i) == 0) continue;
                ids[k] = i;
                dels[k] = d;
                ++k;
            }
        }
        assertEq(k, SAMPLE, "probe: not enough live delegated positions near the slice starts");
    }

    function _read(uint256[] memory ids, address[] memory dels) internal view returns (Snapshot memory s) {
        uint256[4] memory t = _times();
        s.total = veHemi.totalVeHemiSupply();
        s.nonTransferable = veHemi.nonTransferableTotalVeHemiSupply();
        s.forfeitable = veHemi.forfeitableTotalVeHemiSupply();
        (s.bdTotal, s.bdLocked, s.bdForfeitable, s.bdTransferable) = veHemi.supplyBreakdown();
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
            s.votes[i] = vvd.getVotes(dels[i]);
            for (uint256 j = 0; j < t.length; ++j) {
                s.weightAt[i * t.length + j] = veHemi.balanceOfNFTAt(ids[i], t[j]);
                if (j > 0) s.pastVotes[i * (t.length - 1) + j - 1] = vvd.getPastVotes(dels[i], t[j]);
            }
        }
    }

    function test_R31_readersAreContinuousAcrossTheBatch() public {
        if (!live) return;
        (uint256[] memory ids, address[] memory dels) = _sample();
        uint256[4] memory t = _times();
        Snapshot memory a = _read(ids, dels);
        uint256[4] memory supplyBefore;
        for (uint256 j = 0; j < t.length; ++j) supplyBefore[j] = veHemi.totalVeHemiSupplyAt(t[j] - 1);

        _upgradeBoth();
        Snapshot memory b = _read(ids, dels);

        assertEq(b.total, a.total, "totalVeHemiSupply");
        assertEq(b.nonTransferable, a.nonTransferable, "nonTransferableTotalVeHemiSupply");
        assertEq(b.forfeitable, a.forfeitable, "forfeitableTotalVeHemiSupply");
        assertEq(b.bdTotal, a.bdTotal, "supplyBreakdown.total");
        assertEq(b.bdLocked, a.bdLocked, "supplyBreakdown.locked");
        assertEq(b.bdForfeitable, a.bdForfeitable, "supplyBreakdown.forfeitable");
        assertEq(b.bdTransferable, a.bdTransferable, "supplyBreakdown.transferable");
        for (uint256 j = 0; j < t.length; ++j) {
            assertEq(b.totalAt[j], a.totalAt[j], "totalVeHemiSupplyAt");
            assertEq(b.nonTransferableAt[j], a.nonTransferableAt[j], "nonTransferableTotalVeHemiSupplyAt");
            assertEq(b.forfeitableAt[j], a.forfeitableAt[j], "forfeitableTotalVeHemiSupplyAt");
            // By design the quorum denominator now reads one second earlier.
            assertEq(vvd.getPastTotalSupply(t[j]), supplyBefore[j], "getPastTotalSupply(t) != supply at t - 1");
        }
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(b.weight[i], a.weight[i], "balanceOfNFT");
            assertEq(b.votes[i], a.votes[i], "getVotes");
        }
        for (uint256 k = 0; k < a.weightAt.length; ++k) assertEq(b.weightAt[k], a.weightAt[k], "balanceOfNFTAt");
        for (uint256 k = 0; k < a.pastVotes.length; ++k) assertEq(b.pastVotes[k], a.pastVotes[k], "getPastVotes");
    }
}
