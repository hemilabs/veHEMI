// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {AutoRelockLedgerHandler} from "./AutoRelockLedgerHandler.sol";
import {AutoRelockLedgerChecks} from "./AutoRelockLedgerChecks.sol";

/**
 * @title AutoRelockLedgerInvariantBase
 * @notice Deploys `AutoRelockLedgerHandler` and `AutoRelockLedgerChecks`, places a non-transferable and
 *         a forfeitable position, runs the seeding flow (enables on
 *         non-transferable positions are refused until it is finalized) and
 *         arms the first position, so every fuzz run starts with live
 *         subcurves and one flat position.
 */
abstract contract AutoRelockLedgerInvariantBase is Test {
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carl = makeAddr("carl");
    address internal dan = makeAddr("dan");
    address internal earl = makeAddr("earl");

    AutoRelockLedgerHandler internal handler;
    AutoRelockLedgerChecks internal checks;
    VeHemi internal veHemi;
    VeHemiVoteDelegation internal delegation;

    function _setUpCommon() internal {
        handler = new AutoRelockLedgerHandler(admin, [alice, bob, carl, dan, earl]);
        checks = new AutoRelockLedgerChecks(handler);
        veHemi = handler.veHemi();
        delegation = handler.delegation();

        handler.setActorIdx(0);
        handler.createLockedPosition(500 ether, 730 days);
        handler.setActorIdx(1);
        handler.createForfeitablePosition(300 ether, 500 days);
        handler.clearActor();
        handler.seedNow();
        require(veHemi.lockedSeedingFinalized(), "premise: seeding did not finalize");
        handler.enableAutoRelockUnchecked(0);

        targetContract(address(handler));
        for (uint256 i; i < 5; ++i) targetSender(handler.users(i));

        // Setup-only entry points are not fuzz actions.
        bytes4[] memory excluded = new bytes4[](4);
        excluded[0] = AutoRelockLedgerHandler.setActorIdx.selector;
        excluded[1] = AutoRelockLedgerHandler.clearActor.selector;
        excluded[2] = AutoRelockLedgerHandler.enableAutoRelockUnchecked.selector;
        excluded[3] = AutoRelockLedgerHandler.seedNow.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));
    }
}
