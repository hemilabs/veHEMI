// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVeHemi} from "../interfaces/IVeHemi.sol";
import {IRewardDistributor} from "../interfaces/IRewardDistributor.sol";
import {IHemiVoteDelegation} from "../interfaces/IHemiVoteDelegation.sol";

abstract contract VeHemiStorageV1 is IVeHemi {
    IERC20 public immutable HEMI;
    // --- State ---
    uint256 public totalLocked;
    uint256 public epoch;
    uint256 public nextTokenId;

    IHemiVoteDelegation public voteDelegation;

    IRewardDistributor public rewardDistributor; // 0x0 is valid
    mapping(uint256 => Point) public pointHistory; // epoch -> Point
    mapping(uint256 => Point[1000000000]) public userPointHistory; // tokenId -> Point[userEpoch]
    mapping(uint256 => uint256) public userPointEpoch; // tokenId -> epoch
    mapping(uint256 => int128) public slopeChanges; // time -> signed slope change
    mapping(uint256 => LockedBalance) public locked; // tokenId -> LockedBalance
    mapping(uint256 => address) public provider; // tokenId -> address.
    mapping(uint256 => uint256) public transferableAfter; // tokenId -> timestamp // nft transferable from timestamp
}
