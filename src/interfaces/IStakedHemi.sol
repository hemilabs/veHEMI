// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakedHemi {
    // --- Structs ---
    struct Point {
        int128 bias;
        int128 slope;
        uint256 timestamp;
        uint256 blockNumber;
        uint256 amount;
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    struct DelegationCheckpoint {
        uint256 fromTimestamp;
        address owner;
        uint256 delegatedBalance;
        uint256 delegatee;
    }

    // --- Events ---
    event Deposit(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 lockTime,
        uint256 timestamp
    );

    event DelegateChanged(
        address indexed delegator,
        uint256 indexed fromDelegate,
        uint256 indexed toDelegate
    );
    event Withdraw(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 timestamp
    );
    event Supply(uint256 prevSupply, uint256 supply);

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
    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external;
    function withdraw(uint256 tokenId) external;
    function getUserPoint(uint256 tokenId, uint256 epoch) external view returns (Point memory);
    function locked(uint256 tokenId) external view returns (int128 amount, uint256 end);
    function supply() external view returns (uint256);
    function epoch() external view returns (uint256);
    function userPointEpoch(uint256 tokenId) external view returns (uint256);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
}
