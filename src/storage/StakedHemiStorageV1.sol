// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStakedHemi} from "../interfaces/IStakedHemi.sol";
import {IRewardDistributor} from "../interfaces/IRewardDistributor.sol";

abstract contract StakedHemiStorageV1 is IStakedHemi {
    IERC20 public immutable HEMI;
    // --- State ---
    uint256 public supply;
    uint256 public epoch;
    uint256 public nextTokenId;
    IRewardDistributor public rewardDistributor; // 0x0 is valid
    mapping(uint256 => Point) public pointHistory; // epoch -> Point
    mapping(uint256 => Point[1000000000]) public userPointHistory; // tokenId -> Point[userEpoch]
    mapping(uint256 => uint256) public userPointEpoch; // tokenId -> epoch
    mapping(uint256 => int128) public slopeChanges; // time -> signed slope change
    mapping(uint256 => LockedBalance) public locked; // tokenId -> LockedBalance
}
