// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StakedHemi.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC20Mock is ERC20 {
    constructor() ERC20("HEMI", "HEMI") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StakedHemiTest is Test {
    ERC20Mock hemi;
    StakedHemi stakedHemi;
    address user = address(0xBEEF);

    function setUp() public {
        hemi = new ERC20Mock();
        hemi.mint(user, 1_000 ether);

        // Deploy logic contract
        StakedHemi logic = new StakedHemi(address(hemi));
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(StakedHemi.initialize.selector, address(this))
        );
        stakedHemi = StakedHemi(address(proxy));

        vm.prank(user);
        hemi.approve(address(stakedHemi), type(uint256).max);
    }

    function testCreateLock() public {
        uint256 amount = 100 ether;
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 2 * 365 days;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

        // Check NFT ownership
        assertEq(stakedHemi.ownerOf(tokenId), user);

        // Check locked balance
        (int128 lockedAmount, uint256 lockedEnd) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), amount, "Locked amount mismatch");
        assertEq(lockedEnd, (unlockTime / stakedHemi.WEEK()) * stakedHemi.WEEK(), "Unlock time mismatch");

        // Check supply
        assertEq(stakedHemi.supply(), amount, "Supply mismatch");
    }

    function testWithdraw() public {
        uint256 amount = 50 ether;
        uint256 nowTs = block.timestamp;
        uint256 unlockTime = nowTs + 2 weeks;

        vm.prank(user);
        uint256 tokenId = stakedHemi.createLock(amount, unlockTime);

        // Fast forward past unlock
        vm.warp(unlockTime + 1);

        uint256 userBalanceBefore = hemi.balanceOf(user);

        vm.prank(user);
        stakedHemi.withdraw(tokenId);

        // NFT should be burned
        vm.expectRevert();
        stakedHemi.ownerOf(tokenId);

        // User should get tokens back
        uint256 userBalanceAfter = hemi.balanceOf(user);
        assertEq(userBalanceAfter, userBalanceBefore + amount, "Withdraw did not return tokens");

        // Lock should be cleared
        (int128 lockedAmount, uint256 lockedEnd) = stakedHemi.locked(tokenId);
        assertEq(uint256(uint128(lockedAmount)), 0, "Lock not cleared");
        assertEq(lockedEnd, 0, "Lock end not cleared");
    }
}
