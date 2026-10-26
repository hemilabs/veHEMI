// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IVeHemiVoteDelegation} from "../../src/interfaces/IVeHemiVoteDelegation.sol";
import {IRewardDistributor} from "../../src/interfaces/IRewardDistributor.sol";
import "../module-failure/BrokenModules.sol";

/// @title  Module shapes for the move-or-remove armed-transfer leg.
///
/// @notice Each shape isolates one branch of `VeHemi._transferFromUnguarded`'s
///         post-transfer retirement: the MOVE to the recipient's delegate, the
///         FALLBACK REMOVAL, and the both-refused announcement. The real
///         `VeHemiVoteDelegation` is used everywhere a real one can produce the
///         behaviour (saturation, whales); these exist for the branches it
///         cannot (a broken or hostile module).

/// @dev Stores records like a module would and lets the test pre-seed a
///      flat record, so VeHemi's read-back sees something to judge.
abstract contract SeedableRecordModule is BrokenModuleBase {
    mapping(uint256 => Delegation) internal records;

    function seedFlat(uint256 id_, address delegatee_, uint96 bias_) external {
        records[id_] = Delegation({
            delegatee: delegatee_, end: uint48(block.timestamp + 365 days),
            bias: bias_, amount: 0, slope: 0
        });
    }

    function delegation(uint256 id_) external view virtual override returns (Delegation memory) {
        return records[id_];
    }
}

/// @dev MIXED FAILURE. The move (`delegatee != 0`) reverts with a 4-byte
///      custom error; the removal (`delegatee == 0`) reverts with EMPTY data.
///      Two caught failures in one transaction, the second SHORTER than the
///      first: VeHemi's bounded selector copy must clear its scratch word, or
///      the second `DelegationUpdateFailedReason` reports the first selector.
contract MixedFailureModule is SeedableRecordModule {
    error MoveRefused();

    function delegate(uint256, address to_) external pure override {
        if (to_ != address(0)) revert MoveRefused();
        assembly { revert(0, 0) }
    }
}

/// @dev Reverts `delegate` with EXACTLY the configured bytes, whatever their
///      length. Drives VeHemi's catch through every revert-data shape.
contract RawRevertModule is SeedableRecordModule {
    bytes public data;

    function setData(bytes calldata data_) external { data = data_; }

    function delegate(uint256, address) external view override {
        bytes memory revertData = data;
        assembly { revert(add(revertData, 0x20), mload(revertData)) }
    }
}

/// @dev Refuses the move with the real selector and ACCEPTS the removal,
///      recording the gas it was handed at entry, so a test can check that
///      the removal is always handed the whole `DELEGATION_GAS_CEILING`.
contract RemovalGasProbeModule is SeedableRecordModule {
    error DelegationSlopeOverflow();
    uint256 public removalGasAtEntry;
    uint256 public removals;

    function delegate(uint256 id_, address to_) external override {
        uint256 gasAtEntry = gasleft();
        if (to_ != address(0)) revert DelegationSlopeOverflow();
        removalGasAtEntry = gasAtEntry;
        removals += 1;
        delete records[id_];
    }
}

/// @dev THE LIMITATION SHAPE: refuses the move and ACCEPTS the
///      removal as a silent no-op, so its own record stays flat. VeHemi cannot
///      see this from `committed_`; the test asserts that it stays silent.
contract RejectMoveNoopRemovalModule is SeedableRecordModule {
    error MoveRefused();

    function delegate(uint256, address to_) external pure override {
        if (to_ != address(0)) revert MoveRefused();
    }
}

/// @dev Cannot be READ: `delegation()` reverts. Accepts and ignores every
///      write (`delegate` is a no-op). On an armed transfer the move commits
///      and the retirement read-back (`_requireFlatTermRetired`) catches the
///      failed read: it announces and never reverts.
contract ReadRevertingModule is BrokenModuleBase {
    error Unreadable();
    function delegate(uint256, address) external override {}
    function delegation(uint256) external pure override returns (Delegation memory) { revert Unreadable(); }
}

/// @dev A RETURNDATA BOMB on `delegate`: reverts with `size` bytes. VeHemi's
///      catch copies at most the 4-byte selector, where a `catch (bytes memory)`
///      would copy all of it into memory. The armed-transfer tests use
///      2,000,000 bytes: the module's own revert still fits its 8M ceiling, but
///      two full copies in VeHemi (move + removal) do not fit a 29.93M
///      transaction, so the size tells the bounded copy apart from a full one.
contract RevertBombModule is SeedableRecordModule {
    uint256 public size;

    constructor(uint256 size_) { size = size_; }

    function delegate(uint256, address) external view override {
        uint256 n = size;
        assembly { revert(0, n) }
    }
}

/// @dev Burns its whole allowance on `delegate` and then REVERTS (the
///      burn-and-return shape is `OogVoteDelegation`).
contract BurnAndRevertModule is SeedableRecordModule {
    function delegate(uint256, address) external view override {
        uint256 x = 1;
        while (gasleft() > 300) { x = uint256(keccak256(abi.encode(x))); }
        revert();
    }
}

/// @dev Raises the slope-overflow selector WITH TRAILING DATA. On the strict
///      `disableAutoRelock` leg VeHemi re-raises the module's revert data; it
///      must forward all of it, byte for byte.
contract OverflowWithTailModule is SeedableRecordModule {
    function delegate(uint256, address) external pure override {
        bytes memory revertData = abi.encodePacked(bytes4(0xf2b4513c), uint256(0xbeef), bytes3(0x112233));
        assembly { revert(add(revertData, 0x20), mload(revertData)) }
    }
}

/// @dev A reward distributor that, on EVERY notification for `target`,
///      calls the permissionless `retireStrandedFlatTerm(target)` on the
///      delegation module. On an armed transfer the notify-before is refused
///      (`FlatTermNotRetryable`: the flag is still set) and the re-anchor
///      notify succeeds (the {flag 0, flat record} window between
///      `_disarmAutoRelock` and the post-transfer move).
contract RetireStrandedFlatTermDistributor is IRewardDistributor {
    address public immutable vvd;
    uint256 public target;
    uint256 public attempts;
    uint256 public successes;

    constructor(address vvd_) { vvd = vvd_; }

    function setTarget(uint256 id_) external { target = id_; }

    function updateRewards(uint256 tokenId_) external override {
        if (tokenId_ != target) return;
        attempts += 1;
        (bool ok, ) = vvd.call(abi.encodeWithSignature("retireStrandedFlatTerm(uint256)", tokenId_));
        if (ok) successes += 1;
    }
}

/// @dev A reward distributor that burns its whole allowance and returns.
contract BurnAndReturnDistributor is IRewardDistributor {
    function updateRewards(uint256) external view override {
        uint256 x = 1;
        while (gasleft() > 300) { x = uint256(keccak256(abi.encode(x))); }
    }
}

interface IOwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @dev Records `ownerOf(tokenId)` at every notification. The transfer's
///      reward notifications must settle the SELLER's segment: they run before
///      the ownership change.
contract OwnerRecordingDistributor is IRewardDistributor {
    IOwnerOf public immutable ve;
    mapping(uint256 => address[]) internal _owners;

    constructor(address ve_) { ve = IOwnerOf(ve_); }

    function updateRewards(uint256 tokenId_) external override {
        _owners[tokenId_].push(ve.ownerOf(tokenId_));
    }

    function notificationCountFor(uint256 tokenId_) external view returns (uint256) { return _owners[tokenId_].length; }

    function ownerAtNotification(uint256 tokenId_, uint256 index_) external view returns (address) {
        return _owners[tokenId_][index_];
    }
}
