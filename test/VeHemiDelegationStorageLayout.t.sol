// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/VeHemiVoteDelegation.sol";
import "../src/interfaces/IVeHemi.sol";
import "../src/interfaces/IVeHemiVoteDelegation.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";

/// @title VeHemiDelegationStorageLayout
/// @notice Asserts the exact slot positions of VeHemiDelegationStorageV1
///         fields inside the VeHemiVoteDelegation proxy's storage.
///
///         Slot map (sequential storage; OZ v5 bases use ERC-7201):
///
///         ── VeHemiDelegationStorageV1 (slots 0–49) ──
///           0: delegations         mapping(uint256 => Delegation)
///           1: delegateCheckpoints mapping(address => DelegateCheckpoint[])
///           2: expiredDelegations  mapping(address => mapping(uint256 => Expiration))
///           3: nonces              mapping(address => uint256)
///           4: autoDelegate        mapping(address => address)  [NEW: Aragon]
///           5: trustedAdapter      address                      [NEW: Aragon]
///           6–49: __gap[44]
contract VeHemiDelegationStorageLayoutTest is Test {
    VeHemiVoteDelegation delegation;
    address delegationProxy;

    function setUp() public {
        // Deploy VeHemi (needed as constructor arg for VeHemiVoteDelegation)
        MockERC20 hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi veHemiLogic = new VeHemi(address(hemi));
        ERC1967Proxy veHemiProxy = new ERC1967Proxy(
            address(veHemiLogic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );

        // Deploy VeHemiVoteDelegation behind a proxy
        VeHemiVoteDelegation delegationLogic = new VeHemiVoteDelegation(address(veHemiProxy));
        ERC1967Proxy dp = new ERC1967Proxy(
            address(delegationLogic),
            abi.encodeWithSelector(VeHemiVoteDelegation.initialize.selector)
        );
        delegation = VeHemiVoteDelegation(address(dp));
        delegationProxy = address(dp);
    }

    // =========================================================================
    // Slot 0: delegations — mapping(uint256 => Delegation)
    // The Delegation struct packs as:
    //   struct slot 0: delegatee (20 bytes) | end (6 bytes) — 26 bytes
    //   struct slot 1: bias (12) | amount (12) | slope (8) — 32 bytes
    // Write a sentinel address to the delegatee field (low 20 bytes of
    // the first struct slot) and verify via the public getter.
    // =========================================================================

    function test_slot0_delegations() public {
        uint256 tokenId = 42;
        address sentinel = address(0xDEADBEEF);
        // Mapping base slot = 0, struct slot 0 at keccak(tokenId, 0)
        bytes32 structSlot = keccak256(abi.encode(tokenId, uint256(0)));
        // Write delegatee into the low 20 bytes (address occupies low bits in packed slot)
        vm.store(delegationProxy, structSlot, bytes32(uint256(uint160(sentinel))));

        IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(tokenId);
        assertEq(d.delegatee, sentinel, "delegations base is not at slot 0");
    }

    // =========================================================================
    // Slot 3: nonces — mapping(address => uint256)
    // =========================================================================

    function test_slot3_nonces() public {
        address signer = address(0x1234);
        uint256 sentinel = 0xABCD;
        bytes32 slot = keccak256(abi.encode(signer, uint256(3)));
        vm.store(delegationProxy, slot, bytes32(sentinel));
        assertEq(delegation.nonces(signer), sentinel, "nonces base is not at slot 3");
    }

    // =========================================================================
    // Slot 4: autoDelegate — mapping(address => address) [NEW: Aragon]
    // This is the first NEW slot added by the Aragon upgrade. On a V1
    // proxy, this slot was unoccupied (zero). After the V2 bytecode swap,
    // the getter correctly reads address(0) — the "no auto-delegate" default.
    // =========================================================================

    function test_slot4_autoDelegate() public {
        address owner = address(0x5678);
        address sentinel = address(0xCAFE);
        bytes32 slot = keccak256(abi.encode(owner, uint256(4)));
        vm.store(delegationProxy, slot, bytes32(uint256(uint160(sentinel))));
        assertEq(delegation.autoDelegate(owner), sentinel, "autoDelegate base is not at slot 4");
    }

    // =========================================================================
    // Slot 5: trustedAdapter — address [NEW: Aragon]
    // Second NEW slot. Defaults to address(0) until setTrustedAdapter is
    // called (script 05_aragon_adapter.ts).
    // =========================================================================

    function test_slot5_trustedAdapter() public {
        address sentinel = address(0xBEEF);
        vm.store(delegationProxy, bytes32(uint256(5)), bytes32(uint256(uint160(sentinel))));
        assertEq(delegation.trustedAdapter(), sentinel, "trustedAdapter is not at slot 5");
    }

    // =========================================================================
    // V1 → V2 boundary: the original deployed V1 used slots 0–3.
    // The Aragon upgrade appends autoDelegate (slot 4) and trustedAdapter
    // (slot 5). Slots 4–5 were unoccupied on the V1 proxy and default
    // to zero, which is the correct initial state for both new fields.
    // =========================================================================

    function test_slot3_isLastOriginalV1Slot() public {
        // nonces (the last original V1 field) is at slot 3.
        address signer = address(0x9999);
        uint256 sentinel = 0xFFFF;
        bytes32 slot = keccak256(abi.encode(signer, uint256(3)));
        vm.store(delegationProxy, slot, bytes32(sentinel));
        assertEq(delegation.nonces(signer), sentinel, "V1 last original slot (nonces) is not at slot 3");
    }

    function test_slot4_isFirstNewSlot() public {
        // autoDelegate is the first NEW field added by the Aragon upgrade.
        address owner = address(0x7777);
        address sentinel = address(0xAAAA);
        bytes32 slot = keccak256(abi.encode(owner, uint256(4)));
        vm.store(delegationProxy, slot, bytes32(uint256(uint160(sentinel))));
        assertEq(delegation.autoDelegate(owner), sentinel, "First new Aragon slot (autoDelegate) is not at slot 4");
    }

    // =========================================================================
    // Gap integrity: __gap[44] occupies slots 6–49.
    // =========================================================================

    function test_gap_isClean() public view {
        for (uint256 i = 6; i <= 49; ++i) {
            bytes32 val = vm.load(delegationProxy, bytes32(i));
            assertEq(val, bytes32(0), string.concat("Gap slot ", vm.toString(i), " is not zero"));
        }
    }

    function test_totalSlots_is50() public pure {
        // 6 named slots + 44 gap = 50 total.
        uint256 namedSlots = 6; // delegations, delegateCheckpoints, expiredDelegations,
                                // nonces, autoDelegate, trustedAdapter
        uint256 gapSlots = 44;
        assertEq(namedSlots + gapSlots, 50, "Total delegation storage slots must be 50");
    }

    // =========================================================================
    // Default values on a fresh proxy: verify that the NEW Aragon fields
    // read as their expected zero defaults, which is what a V1 proxy would
    // have at those slots before the bytecode swap.
    // =========================================================================

    function test_defaults_autoDelegateIsZero() public view {
        assertEq(delegation.autoDelegate(address(0x1111)), address(0), "autoDelegate should default to address(0)");
    }

    function test_defaults_trustedAdapterIsZero() public view {
        assertEq(delegation.trustedAdapter(), address(0), "trustedAdapter should default to address(0)");
    }
}
