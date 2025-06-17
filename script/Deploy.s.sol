// This file contains the deployment script for MyContract.
// It includes the logic to deploy the contract to a blockchain network.

pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/StakedHemi.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        StakedHemi myContract = new StakedHemi();

        vm.stopBroadcast();
    }
}
