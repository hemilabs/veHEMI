// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../../src/VeHemi.sol";
import "../../src/VeHemiVoteDelegation.sol";
import "../../src/interfaces/IVeHemi.sol";
import "../../src/interfaces/IVeHemiVoteDelegation.sol";
import "../../src/interfaces/IRewardDistributor.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../mocks/MockERC20.sol";

abstract contract K11Base is Test {
    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant SIX_DAYS = YEAR / (12 * 5);
    uint256 internal constant MAX_TIME = 4 * YEAR;

    MockERC20 internal hemi;
    VeHemi internal ve;
    VeHemiVoteDelegation internal del;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal admin = address(0xADAD);

    function _deploy() internal {
        vm.roll(1_000_000);
        vm.warp(2_000 * SIX_DAYS);
        hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        ve = VeHemi(address(proxy));
        del = new VeHemiVoteDelegation(address(ve));
        ve.updateVoteDelegation(IVeHemiVoteDelegation(address(del)));
        ve.markSeedingStarted();
        ve.seedBatch(type(uint256).max);
        ve.finalizeSeeding();
        ve.updateForfeitAdmin(admin);
    }

    function _mint(address owner, uint256 amount, uint256 dur, bool transferable, bool forfeitable)
        internal
        returns (uint256 id)
    {
        hemi.mint(owner, amount);
        vm.startPrank(owner);
        hemi.approve(address(ve), type(uint256).max);
        id = ve.createLockFor(amount, dur, owner, transferable, forfeitable);
        vm.stopPrank();
    }
}
