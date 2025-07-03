// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IStakedHemi is IERC721 {
    // --- Structs ---
    struct Point {
        int128 bias;
        int128 slope;
        uint256 timestamp;
        uint256 blockNumber;
        uint256 amount;
        uint256 permanentBias;
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
        uint256 cooldownPeriod;
        bool cooldownStarted;
    }

    // --- Events ---
    event Deposit(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 lockTime,
        uint256 timestamp
    );

    event Withdraw(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 timestamp
    );
    event Supply(uint256 prevSupply, uint256 supply);
    event Checkpoint(uint256 epoch, uint256 tokenId, LockedBalance oldLock, LockedBalance newLock);

    // --- External/Public Functions ---
    function initialize(address owner, address rewardDistributor) external;
    function checkpoint() external;
    function createLock(uint256 amount, uint256 lockDuration) external returns (uint256 tokenId);
    function createLockFor(
        uint256 amount,
        uint256 lockDuration,
        address account
    ) external returns (uint256 tokenId);
    function increaseAmount(uint256 tokenId, uint256 amount) external;
    function increaseCooldownPeriod(uint256 tokenId, uint256 lockDuration) external;
    function withdraw(uint256 tokenId) external;
    function getUserPoint(uint256 tokenId, uint256 epoch) external view returns (Point memory);
    function getLockedBalance(uint256 tokenId) external view returns (LockedBalance memory);
    function supply() external view returns (uint256);
    function epoch() external view returns (uint256);
    function userPointEpoch(uint256 tokenId) external view returns (uint256);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function balanceOfNFTAt(uint256 tokenId, uint256 timestamp) external view returns (uint256);
}
