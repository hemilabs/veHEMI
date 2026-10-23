// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// @title O05MoveTest
/// @notice The self-transfer entry point. An ERC-721 operator's self-transfer
///         of a position it does not own is refused (`NotOwner`), and the
///         owner's own self-transfer, which re-runs `_delegate` to the same
///         delegatee, opens no zero-second and seals real weight.
contract O05MoveTest is LockedCurveTestBase {
    address internal constant MALLORY = address(0xBAD0);
    address internal constant DEL_A   = address(0xA1);

    function _b(uint256 t) internal pure returns (uint256) { return (t / 1 hours) * 1 hours + 1 hours; }

    function _mk(address o, uint256 a, uint256 d) internal returns (uint256 id) {
        hemi.mint(o, a);
        vm.prank(o); hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(o); id = veHemi.createLock(a, d);
    }

    function _sweep(address d, uint256 from, uint256 to) internal returns (uint256 z, uint256 mn) {
        mn = type(uint256).max;
        for (uint256 t = from; t < to; ++t) {
            vm.warp(t);
            uint256 v = delegation.getVotes(d);
            if (v == 0) { unchecked { ++z; } }
            if (v < mn) mn = v;
        }
    }

    // M1. A decaying position: the operator's self-transfer is refused; the
    //     owner's self-transfer re-books the same delegatee with no
    //     zero-second, and `boundary - 1` seals real weight.
    function test_O05_M1_operatorSelfTransferRefused_ownerReBookOpensNoZeroSecond() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 40 * SIX_DAYS);
        vm.prank(alice); delegation.setAutoDelegate(DEL_A);
        vm.prank(alice); delegation.delegate(id, DEL_A);
        vm.prank(alice); veHemi.setApprovalForAll(MALLORY, true);   // a marketplace approval

        vm.warp(_b(block.timestamp) + 600);
        uint256 full = delegation.getVotes(DEL_A);
        assertGt(full, 0, "precondition");
        uint256 T = block.timestamp;

        // The operator cannot self-transfer a position it does not own. The
        // owner's self-transfer is a supported flow (re-applying
        // `autoDelegate`, see `DelegationBehavior.t.sol`
        // `test_transferFrom_selfTransferIsBenign`) and reaches the same
        // `_resolveAutoDelegate` -> `_delegate` re-book, so the sweep below
        // runs on it.
        vm.prank(MALLORY);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.transferFrom(alice, alice, id);
        vm.prank(alice); veHemi.transferFrom(alice, alice, id);   // the OWNER's own
        assertEq(veHemi.ownerOf(id), alice, "ownership unchanged");

        (uint256 z, ) = _sweep(DEL_A, T + 1, _b(T));
        uint256 S = _b(T) - 1;
        vm.warp(S + 400 days);
        uint256 sealedVotes = delegation.getPastVotes(DEL_A, S);

        assertEq(z, 0, "M1: the owner's self-transfer opened a zero-second");
        assertGt(sealedVotes, 0, "M1: boundary-1 sealed zero");
    }

    // M2. The same on a FLAT (auto-relock) position.
    function test_O05_M2_flatPosition_operatorSelfTransferRefused_ownerReBookOpensNoZeroSecond() public {
        vm.warp(((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1);
        uint256 id = _mk(alice, 500 ether, 40 * SIX_DAYS);
        vm.prank(alice); delegation.setAutoDelegate(DEL_A);
        vm.prank(alice); delegation.delegate(id, DEL_A);
        vm.prank(alice); veHemi.enableAutoRelock(id);
        vm.prank(alice); veHemi.setApprovalForAll(MALLORY, true);

        vm.warp(_b(block.timestamp) + 60);
        assertGt(delegation.getVotes(DEL_A), 0, "precondition");
        uint256 T = block.timestamp;
        vm.prank(MALLORY);
        vm.expectRevert(VeHemi.NotOwner.selector);
        veHemi.transferFrom(alice, alice, id);
        vm.prank(alice); veHemi.transferFrom(alice, alice, id);

        (uint256 z, ) = _sweep(DEL_A, T + 1, _b(T));
        assertEq(z, 0, "M2: the owner's self-transfer opened a zero-second on the flat path");
    }
}
