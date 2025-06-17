// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract StakedHemi {
    // State variables
    uint public value;
    address public owner;

    // Events
    event ValueChanged(uint newValue);

    // Constructor
    constructor() {
        owner = msg.sender;
    }

    // Functions
    function setValue(uint newValue) public {
        require(msg.sender == owner, "Only the owner can set the value");
        value = newValue;
        emit ValueChanged(newValue);
    }

    function getValue() public view returns (uint) {
        return value;
    }
}
