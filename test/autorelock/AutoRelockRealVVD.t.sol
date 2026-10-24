// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../../src/VeHemi.sol";
import "../../src/VeHemiVoteDelegation.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../mocks/MockERC20.sol";

/// @notice Auto-relock against the REAL VeHemiVoteDelegation: the quorum
///         denominator (`getPastTotalSupply`, from `totalVeHemiSupplyAt`)
///         carries the flat term past the position's frozen end.
contract AutoRelockRealVVDTest is Test {
    MockERC20 hemi;
    VeHemi veHemi;
    VeHemiVoteDelegation vvd;

    address owner = address(0xA11CE);

    function setUp() public {
        vm.warp(1_800_000_000);
        hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic), abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));
        vvd = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(vvd);
        hemi.mint(owner, 1_000_000 ether);
        vm.prank(owner);
        hemi.approve(address(veHemi), type(uint256).max);

        veHemi.markSeedingStarted();
        veHemi.seedBatch(type(uint256).max);
        veHemi.finalizeSeeding();
    }

    function _mk(uint256 dur) internal returns (uint256 id) {
        vm.prank(owner);
        id = veHemi.createLock(100 ether, dur);
    }

    /// `totalVeHemiSupplyAt` (the Aragon quorum denominator, read through the
    /// module's `getPastTotalSupply`) carries the flat term after the frozen
    /// end has passed.
    function test_quorumDenominatorCarriesTheFlatTerm() public {
        uint256 id = _mk(400 days);
        vm.prank(owner);
        veHemi.enableAutoRelock(id);
        uint256 w = veHemi.balanceOfNFT(id);
        vm.warp(block.timestamp + 500 days);
        assertLt(veHemi.getLockedBalance(id).end, block.timestamp, "precondition: frozen end is past");
        veHemi.checkpoint();
        assertEq(veHemi.totalVeHemiSupply(), w, "denominator lost the flat term");
        assertEq(vvd.getPastTotalSupply(block.timestamp - 1), w, "past denominator lost it");
    }
}
