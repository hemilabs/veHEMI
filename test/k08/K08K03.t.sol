// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../j11/J11Base.sol";
import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import "./K08Modules.sol";

/// @notice A module whose every READ passes through to the REAL
///         `VeHemiVoteDelegation`, so the
///         record VeHemi reads back is a genuine flat booking made by the
///         genuine module. ONLY `delegate()` is broken. No contrived record,
///         no hand-seeded bias.
contract K08RealPassthrough is IVeHemiVoteDelegation {
    error ModuleBroken();
    IVeHemiVoteDelegation public immutable REAL;
    bool public breakWrites;

    constructor(IVeHemiVoteDelegation real_) { REAL = real_; }
    function setBreakWrites(bool v_) external { breakWrites = v_; }

    function delegate(uint256 id_, address to_) external override {
        if (breakWrites) revert ModuleBroken();
        REAL.delegate(id_, to_);
    }

    function delegation(uint256 id_) external view override returns (Delegation memory) {
        return REAL.delegation(id_);
    }
    function autoDelegate(address a_) external view override returns (address) { return REAL.autoDelegate(a_); }
    function getVotes(address a_) external view override returns (uint256) { return REAL.getVotes(a_); }
    function getPastVotes(address a_, uint256 t_) external view override returns (uint256) { return REAL.getPastVotes(a_, t_); }
    function clearAutoDelegate() external override {}
    function setAutoDelegate(address) external override {}
    function refreshVotingPower(address) external override {}
    function refreshVotingPowerBatch(address[] calldata) external override {}
    function importDelegationsFromLegacy(IVeHemiVoteDelegation, uint256[] calldata) external override {}
    function importAutoDelegatesFromLegacy(IVeHemiVoteDelegation, address[] calldata) external override {}
    function finalizeMigration() external override {}
    function migrationFinalized() external pure override returns (bool) { return false; }
}

/// @title  A readable, write-failing delegation module cannot trap a
///         flat position's principal.
/// @notice With a module that answers `delegation()` (still flat) but refuses
///         `delegate()`, the holder's `disableAutoRelock` commits, `withdraw`
///         then returns the full principal, and the permissionless
///         `retireStaleAutoRelock` commits too -- including five years after
///         it opens. A module that answers a still-flat record for every id
///         and silently drops writes is covered as well. A decaying control
///         runs on the read-passthrough module.
contract K08K03 is J11Base {
    uint256 constant MT = 4 * 365.25 days;

    /// @dev 100 HEMI, 4-year lock, auto-relock on, a readable write-failing
    ///      module (`K08HalfBroken`).
    function test_K08_K03_flatPositionIsNoLongerTrapped() public {
        (uint256 id, , ) = createLock(attacker, 100 ether, MT);
        K08HalfBroken hb = new K08HalfBroken();
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(hb)));
        enable(attacker, id);
        hb.seedFlat(id, dele, uint96(veHemi.balanceOfNFT(id)));

        // 1. the holder's own disable COMMITS.
        disable(attacker, id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "a write-failing module blocked the holder's disable");

        // 2. and the principal comes home, with no admin action anywhere.
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 100 ether, "a write-failing module trapped the principal");
    }

    /// @dev The PERMISSIONLESS keeper remedy must work too, since it is the
    ///      only exit that does not need the position's owner to be alive.
    function test_K08_K03_permissionlessRetireIsNoLongerRefused() public {
        (uint256 id, , ) = createLock(attacker, 100 ether, MT);
        K08HalfBroken hb = new K08HalfBroken();
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(hb)));
        enable(attacker, id);
        hb.seedFlat(id, dele, uint96(veHemi.balanceOfNFT(id)));
        vm.warp(veHemi.autoRelockStaleAt(id));
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "a write-failing module blocked the permissionless retire");
    }

    /// @dev The scenario is not a hostile owner --
    ///      `VeHemi.owner()` is the same Safe as `ProxyAdmin.owner()`, which
    ///      can already replace the implementation outright, so a hostile
    ///      owner needs no such trick. It is the ACCIDENT: one module that
    ///      answers `delegation()` with a still-flat record for every id.
    ///      Two independent holders, neither of whom did anything.
    function test_K08_K03_unanticipatedModuleNoLongerFreezesEveryHolder() public {
        (uint256 idA, , ) = createLock(attacker, 100 ether, MT);
        (uint256 idB, , ) = createLock(victim, 250 ether, MT);
        enable(attacker, idA);
        enable(victim, idB);

        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(new K08SilentFreeze())));

        disable(attacker, idA);
        disable(victim, idB);
        assertEq(veHemi.autoRelockRemaining(idA), 0, "A still frozen");
        assertEq(veHemi.autoRelockRemaining(idB), 0, "B still frozen");

        vm.warp(uint256(veHemi.getLockedBalance(idA).end) + 1);
        uint256 a0 = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(idA);
        assertEq(hemi.balanceOf(attacker) - a0, 100 ether, "A principal still trapped");
        uint256 b0 = hemi.balanceOf(victim);
        vm.prank(victim);
        veHemi.withdraw(idB);
        assertEq(hemi.balanceOf(victim) - b0, 250 ether, "B principal still trapped");
    }

    /// @dev Reads pass through to the REAL VVD (so the flat record is genuine,
    ///      not seeded); only `delegate()` reverts. The holder's disable and
    ///      then withdraw must both succeed, with the full principal back.
    function test_K08_K12_realPassthroughModuleTrapsNothing() public {
        uint256 id = _flatGenuine(attacker);
        uint256 booked = delegation.getVotes(dele);
        assertGt(booked, 0, "probe: the REAL module booked no flat term");

        K08RealPassthrough pt = new K08RealPassthrough(IVeHemiVoteDelegation(address(delegation)));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(pt)));
        pt.setBreakWrites(true);

        // exit 1 -- the holder's own disable
        disable(attacker, id);
        assertEq(veHemi.autoRelockRemaining(id), 0, "the read-passthrough module blocked the holder's disable");

        // exit 2 -- withdraw
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 1_000 ether, "the read-passthrough module trapped the principal");
    }

    /// @dev The permissionless leg, on the same passthrough module.
    function test_K08_K12_realPassthroughPermissionlessRetire() public {
        uint256 id = _flatGenuine(victim);
        K08RealPassthrough pt = new K08RealPassthrough(IVeHemiVoteDelegation(address(delegation)));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(pt)));
        pt.setBreakWrites(true);
        vm.warp(veHemi.autoRelockStaleAt(id) + 5 * 365 days);
        vm.prank(stranger);
        veHemi.retireStaleAutoRelock(id);
        assertEq(veHemi.autoRelockRemaining(id), 0,
            "the read-passthrough module blocked the permissionless retire at staleAt + 5y");
    }

    /// @dev DECAYING control: it must still return the full principal. If this
    ///      is red the failure is in the harness.
    function test_K08_K12_decayingControl() public {
        (uint256 id, , ) = createLock(attacker, 1_000 ether, 2 * 365 days);
        delegateTo(attacker, id, dele);
        K08RealPassthrough pt = new K08RealPassthrough(IVeHemiVoteDelegation(address(delegation)));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(pt)));
        pt.setBreakWrites(true);
        vm.warp(uint256(veHemi.getLockedBalance(id).end) + 1);
        uint256 before = hemi.balanceOf(attacker);
        vm.prank(attacker);
        veHemi.withdraw(id);
        assertEq(hemi.balanceOf(attacker) - before, 1_000 ether, "control: decaying principal trapped");
    }

    function _flatGenuine(address who_) internal returns (uint256 id) {
        (id, , ) = createLock(who_, 1_000 ether, 4 * 365 days);
        enable(who_, id);
        delegateTo(who_, id, dele);
        vm.warp(block.timestamp + 7200);
    }
}
