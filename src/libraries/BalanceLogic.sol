// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {SafeCast} from "./SafeCast.sol";
import {IStakedHemi} from "../interfaces/IStakedHemi.sol";

library BalanceLogic {
    using SafeCast for uint256;
    using SafeCast for int128;
}
