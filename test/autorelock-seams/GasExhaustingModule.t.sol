// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockSeamsBase.sol";
import "../mocks/RevertingVoteDelegation.sol";
import "../mocks/OogVoteDelegation.sol";

contract GasExhaustingModuleTest is AutoRelockSeamsBase {
    function setUp() public { _deploy(); }

    // A broken delegation module must never lock a victim's principal.
    // Control: a CHEAP-reverting module (`RevertingVoteDelegation`, which
    // reverts at once).
    function test_cheapRevertingModule_withdraw_ok() public {
        uint256 id = _mint(alice, 1000e18, 3 * SIX_DAYS, true, false);
        ve.updateVoteDelegation(IVeHemiVoteDelegation(address(new RevertingVoteDelegation())));
        vm.warp(ve.getLockedBalance(id).end + 1);
        uint256 balanceBefore = hemi.balanceOf(alice);
        vm.prank(alice);
        ve.withdraw(id);
        assertEq(hemi.balanceOf(alice) - balanceBefore, 1000e18, "principal trapped (cheap revert)");
    }

    // The same property with a module that breaks by EXHAUSTING GAS.
    function test_gasExhaustingModule_withdraw() public {
        uint256 id = _mint(alice, 1000e18, 3 * SIX_DAYS, true, false);
        ve.updateVoteDelegation(IVeHemiVoteDelegation(address(new OogVoteDelegation())));
        vm.warp(ve.getLockedBalance(id).end + 1);
        uint256 balanceBefore = hemi.balanceOf(alice);
        vm.prank(alice);
        ve.withdraw(id);
        assertEq(hemi.balanceOf(alice) - balanceBefore, 1000e18, "PRINCIPAL TRAPPED behind a gas-exhausting delegation module");
    }

    // Same for a FLAT position: disable then withdraw.
    function test_gasExhaustingModule_disable_then_withdraw() public {
        uint256 id = _mint(alice, 1000e18, 10 * SIX_DAYS, true, false);
        vm.prank(alice);
        ve.enableAutoRelock(id);
        ve.updateVoteDelegation(IVeHemiVoteDelegation(address(new OogVoteDelegation())));
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        vm.prank(alice);
        ve.disableAutoRelock(id);
        vm.warp(ve.getLockedBalance(id).end + 1);
        uint256 balanceBefore = hemi.balanceOf(alice);
        vm.prank(alice);
        ve.withdraw(id);
        assertEq(hemi.balanceOf(alice) - balanceBefore, 1000e18, "PRINCIPAL TRAPPED (flat path)");
    }

    // Forfeit (admin) against the same module.
    function test_gasExhaustingModule_forfeit() public {
        uint256 id = _mint(alice, 1000e18, 10 * SIX_DAYS, false, true);
        ve.updateVoteDelegation(IVeHemiVoteDelegation(address(new OogVoteDelegation())));
        vm.warp(block.timestamp + SIX_DAYS);
        vm.prank(admin);
        ve.forfeit(id);
    }

    // createLock / transferFrom against the same module.
    function test_gasExhaustingModule_createLock_and_transfer() public {
        ve.updateVoteDelegation(IVeHemiVoteDelegation(address(new OogVoteDelegation())));
        uint256 id = _mint(alice, 1000e18, 10 * SIX_DAYS, true, false);
        vm.prank(alice);
        ve.transferFrom(alice, bob, id);
    }
}
