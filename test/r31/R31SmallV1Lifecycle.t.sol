// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./R31Base.sol";

/// @title  A sub-10-HEMI V1 position through the auto-relock lifecycle.
/// @notice On a Hemi mainnet fork (skips without HEMI_RPC_URL; pinned by
///         R31_FORK_BLOCK), executes the upgrade batch, then takes a live,
///         delegated V1 position whose amount is below today's 10-HEMI
///         minimum (V1 minted such positions; at the default pin id 8 holds
///         2.625e-7 HEMI) through the auto-relock lifecycle: enable, heartbeat,
///         owner disable and withdraw at the restored end, and, from a second
///         enable, the permissionless stale retirement. Each step is compared
///         with a twin of the same state in which it was not taken: the
///         delegatee's votes move by exactly the position's weight change.
contract R31SmallV1LifecycleTest is R31Base {
    uint256 internal constant MIN_LOCK_AMOUNT = 10e18;
    uint256 internal constant MAX_TIME = 4 * 365.25 days;

    VeHemi internal ve;
    uint256 internal id;
    address internal owner;
    address internal dele;
    uint256 internal amount;

    function setUp() public override {
        super.setUp();
        if (!live) return;
        ve = VeHemi(VEHEMI_PROXY);
        (id, owner, dele) = _pickSmallV1();
        amount = uint256(uint128(veHemi.getLockedBalance(id).amount));
        _upgradeBoth();
        _toAfterB(_nb(block.timestamp));
        assertFalse(vvd.legacyDatingActive(), "premise: window still open");
    }

    /// @dev Live, delegated, V1-minted (no `transferableAfter`), below the
    ///      minimum, and at least three buckets from its end.
    function _pickSmallV1() internal view returns (uint256, address, address) {
        uint256[3] memory candidates = [uint256(8), 2, 3];
        for (uint256 k; k < candidates.length; ++k) {
            uint256 i = candidates[k];
            IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(i);
            if (lb.amount <= 0 || uint256(uint128(lb.amount)) >= MIN_LOCK_AMOUNT) continue;
            if (veHemi.transferableAfter(i) != 0) continue;
            if (uint256(lb.end) < block.timestamp + 3 * SIX_DAYS) continue;
            (address d,,,,) = vvd.delegations(i);
            if (d == address(0)) continue;
            return (i, veHemi.ownerOf(i), d);
        }
        revert("R31: no live delegated sub-10-HEMI V1 position among the candidates");
    }

    function _weight() internal view returns (uint256) {
        try ve.balanceOfNFT(id) returns (uint256 w) {
            return w;
        } catch {
            return 0;
        }
    }

    /// @dev Takes the step as `caller_` and checks it against a twin without
    ///      it, one second later (where a write outside the window lands).
    function _step(address caller_, bytes memory data_, string memory what_) internal {
        uint256 snap = vm.snapshotState();
        _to(block.timestamp + 1);
        uint256 wNo = _weight();
        uint256 vNo = vvd.getVotes(dele);
        vm.revertToState(snap);

        vm.prank(caller_);
        (bool ok, bytes memory ret) = VEHEMI_PROXY.call(data_);
        if (!ok) {
            emit log_named_bytes(string.concat(what_, ": revert data"), ret);
            revert(string.concat(what_, ": reverted on a sub-10-HEMI V1 position"));
        }
        _to(block.timestamp + 1);
        uint256 wYes = _weight();
        uint256 vYes = vvd.getVotes(dele);
        assertEq(
            int256(vYes) - int256(vNo),
            int256(wYes) - int256(wNo),
            string.concat(what_, ": the delegatee's votes did not move by the position's weight change")
        );
    }

    function _assertFlatAtDelegatee(string memory what_) internal view {
        assertTrue(ve.isAutoRelockEnabled(id), string.concat(what_, ": not armed"));
        IVeHemiVoteDelegation.Delegation memory d = vvd.delegation(id);
        assertEq(d.delegatee, dele, string.concat(what_, ": record moved off the delegatee"));
        assertTrue(d.slope == 0 && d.bias > 0, string.concat(what_, ": record not flat"));
        uint256 r = uint256(ve.autoRelockRemaining(id));
        assertEq(_weight(), (amount / MAX_TIME) * (r - SIX_DAYS / 2), string.concat(what_, ": not at the bucket-mean level"));
    }

    function _assertDecayingAtDelegatee(string memory what_) internal view {
        assertFalse(ve.isAutoRelockEnabled(id), string.concat(what_, ": still armed"));
        IVeHemiVoteDelegation.Delegation memory d = vvd.delegation(id);
        assertEq(d.delegatee, dele, string.concat(what_, ": record moved off the delegatee"));
        assertGt(d.slope, 0, string.concat(what_, ": record not decaying"));
    }

    function test_R31_smallV1_enableRefreshDisableWithdraw() public {
        if (!live) return;
        emit log_named_uint("V1 position", id);
        emit log_named_uint("amount (wei)", amount);
        assertGt(amount / MAX_TIME, 0, "premise: the position has no slope");

        _step(owner, abi.encodeCall(VeHemi.enableAutoRelock, (id)), "enable");
        _assertFlatAtDelegatee("enable");
        uint256 r = uint256(ve.autoRelockRemaining(id));
        uint256 level = _weight();

        _to(block.timestamp + 10 days);
        assertEq(_weight(), level, "the flat weight moved");
        uint256 staleBefore = ve.autoRelockStaleAt(id);
        _step(owner, abi.encodeCall(VeHemi.refreshAutoRelock, (id)), "refresh");
        assertGt(ve.autoRelockStaleAt(id), staleBefore, "refresh did not restart the clock");
        _assertFlatAtDelegatee("refresh");

        uint256 restored = (block.timestamp / SIX_DAYS) * SIX_DAYS + r;
        _step(owner, abi.encodeCall(VeHemi.disableAutoRelock, (id)), "disable");
        _assertDecayingAtDelegatee("disable");
        assertEq(uint256(ve.getLockedBalance(id).end), restored, "disable did not restore grid(now) + R");

        _to(restored);
        uint256 bal = IERC20R31(HEMI_TOKEN).balanceOf(owner);
        _step(owner, abi.encodeCall(VeHemi.withdraw, (id)), "withdraw");
        assertEq(IERC20R31(HEMI_TOKEN).balanceOf(owner) - bal, amount, "principal not returned in full");
        assertEq(vvd.delegation(id).delegatee, address(0), "withdraw left a delegation record");
    }

    function test_R31_smallV1_enableThenStaleRetire() public {
        if (!live) return;
        _step(owner, abi.encodeCall(VeHemi.enableAutoRelock, (id)), "enable");
        _assertFlatAtDelegatee("enable");
        _to(ve.autoRelockStaleAt(id));
        _step(address(0x5747A9E1), abi.encodeCall(VeHemi.retireStaleAutoRelock, (id)), "stale retire");
        _assertDecayingAtDelegatee("stale retire");
    }
}
