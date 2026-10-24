// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";

/// @title  Broken delegation modules, one behaviour each.
///
/// @notice A module that reverts on reads AND writes
///         (`RevertingVoteDelegation`) takes the tolerated `catch` branch and
///         never reaches the flat-term read-back. These shapes cover the
///         modules VeHemi CAN read, so "a broken module cannot lock principal"
///         is tested as a matrix (BrokenModuleMatrixTest,
///         WriteBrokenModuleTest, SlopeOverflowReRaiseTest,
///         StarvationCeilingTest and the armed-transfer suites) rather than as
///         a single "broken" case:
///
///           B1  reverts on everything      (test/mocks/RevertingVoteDelegation.sol)
///           B2  reverts on WRITE, succeeds on READ
///           B3  succeeds and LIES          (test/mocks/LyingVoteDelegation.sol)
///           B4  succeeds and returns STALE (a cache that never invalidates)
///           B5  succeeds and returns a CONSTANT flat record for every id
///           B6  out-of-gas on the WRITE path
///           B7  out-of-gas on the READ path
///           B8  returns GARBAGE (undecodable returndata)
///           B9  MUTE -- every selector reverts with empty returndata
// =====================================================================

/// @dev Shared no-op tail so each shape below states only what makes it
///      different. `delegate` and `delegation` are left out of the base so
///      each module can declare them with its own mutability.
abstract contract BrokenModuleBase is IVeHemiVoteDelegation {
    function getVotes(address) external pure virtual override returns (uint256) { return 0; }
    function getPastVotes(address, uint256) external pure virtual override returns (uint256) { return 0; }
    function autoDelegate(address) external view virtual override returns (address) { return address(0); }
    function clearAutoDelegate() external override {}
    function setAutoDelegate(address) external override {}
    function refreshVotingPower(address) external override {}
    function refreshVotingPowerBatch(address[] calldata) external override {}
    function importDelegationsFromLegacy(IVeHemiVoteDelegation, uint256[] calldata) external override {}
    function importAutoDelegatesFromLegacy(IVeHemiVoteDelegation, address[] calldata) external override {}
    function finalizeMigration() external override {}
    function migrationFinalized() external pure override returns (bool) { return false; }
}

/// B2 — READABLE, WRITE-FAILING. A paused / version-skewed / buggy proxy.
///      Reads answer truthfully and the answer is STILL FLAT, so
///      `_requireFlatTermRetired` reaches its `revert`, not its `catch`.
contract HalfBrokenModule is BrokenModuleBase {
    error ModuleBroken();
    mapping(uint256 => Delegation) internal recs;

    function seedFlat(uint256 id_, address delegatee_, uint96 bias_) external {
        recs[id_] = Delegation({
            delegatee: delegatee_, end: uint48(block.timestamp + 365 days),
            bias: bias_, amount: 0, slope: 0
        });
    }

    function delegate(uint256, address) external pure override { revert ModuleBroken(); }
    function delegation(uint256 id_) external view override returns (Delegation memory) { return recs[id_]; }
}

/// B4 — SUCCEEDS AND RETURNS STALE. `delegate` is accepted and recorded, but
///      `delegation` serves a snapshot taken before the write: an ordinary
///      cache-invalidation bug. No revert anywhere; the record VeHemi reads
///      back is the pre-retirement flat one.
contract StaleReaderModule is BrokenModuleBase {
    mapping(uint256 => Delegation) internal live;
    mapping(uint256 => Delegation) internal stale;
    mapping(uint256 => bool) internal frozen;

    function freezeAt(uint256 id_, address delegatee_, uint96 bias_) external {
        stale[id_] = Delegation({
            delegatee: delegatee_, end: uint48(block.timestamp + 365 days),
            bias: bias_, amount: 0, slope: 0
        });
        frozen[id_] = true;
    }

    function delegate(uint256 id_, address to_) external override {
        live[id_] = Delegation({
            delegatee: to_, end: uint48(block.timestamp + 365 days),
            bias: 1, amount: 0, slope: 1
        });
    }

    function delegation(uint256 id_) external view override returns (Delegation memory) {
        return frozen[id_] ? stale[id_] : live[id_];
    }
}

/// B5 — SUCCEEDS AND LIES GLOBALLY. Never reverts on any selector; `delegate`
///      is a silent no-op and `delegation` reports a flat-looking record for
///      EVERY id. One `onlyOwner`, un-timelocked `updateVoteDelegation` call
///      installs it.
contract SilentFreezeModule is BrokenModuleBase {
    function delegate(uint256, address) external override {}
    function delegation(uint256) external view override returns (Delegation memory) {
        return Delegation({
            delegatee: address(0xdead), end: uint48(block.timestamp + 1 days),
            bias: 1, amount: 0, slope: 0
        });
    }
}

/// B6 — OUT-OF-GAS ON THE WRITE. Reads are cheap and truthful (still flat);
///      `delegate` consumes every unit of gas it is handed. The starvation
///      handling (`_requireNotStarved`, the delegation gas ceiling) is under
///      test here, not the retirement read-back.
contract GasEaterWriteModule is BrokenModuleBase {
    mapping(uint256 => Delegation) internal recs;

    function seedFlat(uint256 id_, address delegatee_, uint96 bias_) external {
        recs[id_] = Delegation({
            delegatee: delegatee_, end: uint48(block.timestamp + 365 days),
            bias: bias_, amount: 0, slope: 0
        });
    }

    function delegate(uint256, address) external pure override {
        uint256 x = 1;
        while (true) { x = uint256(keccak256(abi.encode(x))); }
    }

    function delegation(uint256 id_) external view override returns (Delegation memory) { return recs[id_]; }
}

/// B7 — OUT-OF-GAS ON THE READ. `delegation` burns its whole allowance, so
///      `_reDelegate`'s OWN read starves before any write is attempted.
contract GasEaterReadModule is BrokenModuleBase {
    function delegate(uint256, address) external override {}
    function delegation(uint256) external view override returns (Delegation memory) {
        uint256 x = 1;
        while (true) { x = uint256(keccak256(abi.encode(x))); }
    }
}

/// B8 — RETURNS GARBAGE. `delegation` succeeds with 31 bytes of returndata,
///      which cannot be ABI-decoded as `Delegation`. Solidity's try/catch does
///      not catch a return-data decode failure: it reverts in the caller.
contract GarbageModule is BrokenModuleBase {
    function delegate(uint256, address) external override {}

    function delegation(uint256) external pure override returns (Delegation memory) {
        assembly {
            mstore(0x00, 0xdeadbeef)
            return(0x00, 0x1f) // 31 bytes: never a valid `Delegation`
        }
    }
}

/// B9 — MUTE. Every selector reverts with empty returndata, cheaply: the
///      version-skew / missing-implementation shape.
contract MuteModule {
    fallback() external { revert(); }
}
