// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {VeHemi} from "../../src/VeHemi.sol";

contract MockVeHemi is VeHemi {
    constructor(address hemi_) VeHemi(hemi_) {}

    function _reDelegate(uint256 delegator_) internal override {}
}
