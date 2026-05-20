// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import "../src/interfaces/IVeHemi.sol";

interface IVeHemiV1 {
    function forfeitable(uint256 tokenId) external view returns (bool);
    function transferableAfter(uint256 tokenId) external view returns (uint256);
    function getLockedBalance(uint256 tokenId) external view returns (IVeHemi.LockedBalance memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function nextTokenId() external view returns (uint256);
}

/// @notice Scans Hemi mainnet for non-transferable and forfeitable positions.
///         Run with: forge script script/ScanForfeitable.s.sol --rpc-url $HEMI_RPC_URL
contract ScanForfeitable is Script {
    address constant VEHEMI_PROXY = 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89;

    function run() external view {
        IVeHemiV1 veHemi = IVeHemiV1(VEHEMI_PROXY);

        // Scan known non-transferrable range. Mainnet only uses createLockFor for
        // non-transferrable positions and these are concentrated in tokens 28625-28809.
        uint256 start = 28625;
        uint256 end = 28810;

        uint256 nonTransferableCount;
        uint256 forfeitableCount;
        uint256 activeNonTransferable;
        uint256 activeForfeitable;

        for (uint256 i = start; i < end; i++) {
            address owner;
            try veHemi.ownerOf(i) returns (address o) {
                owner = o;
            } catch {
                continue;
            }
            if (owner == address(0)) continue;

            bool isNonTransferable = veHemi.transferableAfter(i) != 0;
            bool isForfeitable = veHemi.forfeitable(i);

            if (isNonTransferable) nonTransferableCount++;
            if (isForfeitable) forfeitableCount++;

            IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(i);
            bool isActive = bal.amount > 0 && bal.end > block.timestamp;

            if (isNonTransferable && isActive) activeNonTransferable++;
            if (isForfeitable && isActive) activeForfeitable++;

            if (isForfeitable) {
                console.log("Forfeitable token:", i, "active:", isActive ? 1 : 0);
            }
        }

        console.log("=== SCAN RESULTS (range 28625-28809) ===");
        console.log("Non-transferable total:", nonTransferableCount);
        console.log("Non-transferable active:", activeNonTransferable);
        console.log("Forfeitable total:", forfeitableCount);
        console.log("Forfeitable active:", activeForfeitable);
    }
}
