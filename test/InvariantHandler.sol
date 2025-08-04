// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IVeHemi} from "src/interfaces/IVeHemi.sol";

contract InvariantHandler is Test {
    VeHemi public veHemi;
    VeHemiVoteDelegation public delegation;
    MockERC20 public hemi;

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant MONTH = YEAR / 12;
    uint256 private constant SIX_DAYS = MONTH / 5;

    uint256 private constant MIN_AMOUNT = 0.000001e18;
    uint256 private constant MAX_AMOUNT = 1_000e18;

    uint256 private constant MIN_DURATION = 2 * SIX_DAYS;
    uint256 private constant MAX_DURATION = 4 * YEAR;

    uint256 MAX_ACCUMULATED_WARP = SIX_DAYS * 255; // max duration between checkpoints the `totalVeHemiSupply()` supports
    uint256 maxWarp = MAX_ACCUMULATED_WARP;

    address[5] public users;

    constructor(address admin_, address[5] memory _users) {
        users = _users;

        hemi = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemi));

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, admin_)
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));

        vm.startPrank(admin_);
        veHemi.updateVoteDelegation(delegation);
        veHemi.updateForfeitAdmin(admin_);
        vm.stopPrank();
    }

    // Return 0x0 instead of reverting if the NFT does not exist anymore
    function _ownerOf(uint256 tokenId) public returns (address from) {
        (, bytes memory data) = address(veHemi).call(
            abi.encodeWithSignature("ownerOf(uint256)", tokenId)
        );

        assembly {
            from := mload(add(data, 32))
        }
    }

    function createLock(uint256 amount, uint256 duration) public returns (uint256 tokenId) {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);

        vm.startPrank(msg.sender);
        hemi.mint(msg.sender, amount);
        hemi.approve(address(veHemi), amount);
        tokenId = veHemi.createLock(amount, duration);
        vm.stopPrank();

        maxWarp = MAX_ACCUMULATED_WARP;
    }

    function createLockFor(uint256 amount, uint256 duration) public returns (uint256 tokenId) {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);

        vm.startPrank(veHemi.owner());
        hemi.mint(veHemi.owner(), amount);
        hemi.approve(address(veHemi), amount);
        tokenId = veHemi.createLockFor(amount, duration, msg.sender, true, true);
        vm.stopPrank();

        maxWarp = MAX_ACCUMULATED_WARP;
    }

    function forfeit() public {
        for (uint256 id; id < veHemi.nextTokenId(); id++) {
            if (!veHemi.forfeitable(id)) continue;
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            if (_lock.end < block.timestamp) continue;

            vm.prank(veHemi.forfeitAdmin());
            veHemi.forfeit(id);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function increaseAmount(uint256 amount) public {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);

            if (_lock.amount == 0) continue;
            if (_lock.end < block.timestamp) continue;

            address owner = veHemi.ownerOf(id);

            vm.startPrank(owner);
            hemi.mint(owner, amount);
            hemi.approve(address(veHemi), amount);
            veHemi.increaseAmount(id, amount);
            vm.stopPrank();

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function increaseUnlockTime(uint256 duration) public {
        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            if (block.timestamp > _lock.end) continue;
            uint256 currentDuration = _lock.end - block.timestamp;
            if (currentDuration + SIX_DAYS > MAX_DURATION) continue;

            duration = bound(duration, currentDuration + SIX_DAYS, MAX_DURATION);

            vm.prank(owner);
            veHemi.increaseUnlockTime(id, duration);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function transfer(uint256 rand) public {
        address to = users[rand % users.length];

        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address from = _ownerOf(id);

            if (from == address(0) || to == from) continue;

            vm.prank(from);
            veHemi.transferFrom(from, to, id);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function withdraw() public {
        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);

            if (block.timestamp < _lock.end) continue;

            vm.prank(owner);
            veHemi.withdraw(id);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function delegate(uint256 rand) public {
        address delegatee = users[rand % users.length];

        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);

            uint256 _nextCheckpoint = ((block.timestamp / 1 days) * 1 days) + 1 days;

            if (_nextCheckpoint >= _lock.end) continue;

            vm.prank(owner);
            delegation.delegate(id, delegatee);

            break;
        }
    }

    function warp(uint256 time) public {
        if (maxWarp == 0) return;

        time = bound(time, 1, maxWarp);
        vm.warp(block.timestamp + time);

        maxWarp -= time;
    }
}
