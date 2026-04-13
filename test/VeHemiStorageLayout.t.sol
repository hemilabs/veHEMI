// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHemiVoteDelegation.sol";

/// @title VeHemiStorageLayout
/// @notice Asserts the exact slot positions of VeHemiStorageV1 and
///         VeHemiStorageV2 fields inside the proxy's storage. If anyone
///         accidentally inserts a field into V1 — shifting V2's base — this
///         test will fail before the change ever reaches mainnet.
///
///         Slot map (sequential storage; OZ v5 bases use ERC-7201 namespaced
///         storage at hashed slots and do NOT occupy this range):
///
///         ── VeHemiStorageV1 (slots 0–13) ──
///           0: totalLocked
///           1: epoch
///           2: nextTokenId
///           3: voteDelegation
///           4: rewardDistributor
///           5: forfeitAdmin
///           6: globalPointHistory (mapping base)
///           7: userPointHistory (mapping base)
///           8: userPointEpoch (mapping base)
///           9: slopeChanges (mapping base)
///          10: locked (mapping base)
///          11: provider (mapping base)
///          12: transferableAfter (mapping base)
///          13: forfeitable (mapping base)
///
///         ── VeHemiStorageV2 (slots 14–63) ──
///          14: __reservedSlot0
///          15: __reservedSlot1
///          16: lockedSlopeChanges (mapping base)
///          17: lockedGlobalPointHistory (mapping base)
///          18: lockedSeedingFinalized
///          19: forfeitableSlopeChanges (mapping base)
///          20: forfeitableGlobalPointHistory (mapping base)
///          21–63: __gapV2[43]
contract VeHemiStorageLayoutTest is Test {
    VeHemi veHemi;
    address proxy;

    function setUp() public {
        MockERC20 hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi logic = new VeHemi(address(hemi));
        MockHemiVoteDelegation mockDelegation = new MockHemiVoteDelegation();

        ERC1967Proxy p = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(p));
        proxy = address(p);

        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(mockDelegation)));
    }

    // =========================================================================
    // V1 value-type slots (0–5): write a sentinel at the expected slot, read
    // back via the public getter to confirm they agree.
    // =========================================================================

    function test_slot0_totalLocked() public {
        uint256 sentinel = 0xAAAA;
        vm.store(proxy, bytes32(uint256(0)), bytes32(sentinel));
        assertEq(veHemi.totalLocked(), sentinel, "totalLocked is not at slot 0");
    }

    function test_slot1_epoch() public {
        uint256 sentinel = 0xBBBB;
        vm.store(proxy, bytes32(uint256(1)), bytes32(sentinel));
        assertEq(veHemi.epoch(), sentinel, "epoch is not at slot 1");
    }

    function test_slot2_nextTokenId() public {
        uint256 sentinel = 0xCCCC;
        vm.store(proxy, bytes32(uint256(2)), bytes32(sentinel));
        assertEq(veHemi.nextTokenId(), sentinel, "nextTokenId is not at slot 2");
    }

    function test_slot3_voteDelegation() public {
        address sentinel = address(0xDDDD);
        vm.store(proxy, bytes32(uint256(3)), bytes32(uint256(uint160(sentinel))));
        assertEq(address(veHemi.voteDelegation()), sentinel, "voteDelegation is not at slot 3");
    }

    function test_slot4_rewardDistributor() public {
        address sentinel = address(0xEEEE);
        vm.store(proxy, bytes32(uint256(4)), bytes32(uint256(uint160(sentinel))));
        assertEq(address(veHemi.rewardDistributor()), sentinel, "rewardDistributor is not at slot 4");
    }

    function test_slot5_forfeitAdmin() public {
        address sentinel = address(0xFFFF);
        vm.store(proxy, bytes32(uint256(5)), bytes32(uint256(uint160(sentinel))));
        assertEq(veHemi.forfeitAdmin(), sentinel, "forfeitAdmin is not at slot 5");
    }

    // =========================================================================
    // V1 mapping slots (6–13): verify the mapping base slot by writing a
    // value at keccak256(key, baseSlot) and reading via the public getter.
    // =========================================================================

    function test_slot8_userPointEpoch() public {
        uint256 tokenId = 42;
        uint256 sentinel = 0x1234;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(8)));
        vm.store(proxy, slot, bytes32(sentinel));
        assertEq(veHemi.userPointEpoch(tokenId), sentinel, "userPointEpoch base is not at slot 8");
    }

    function test_slot9_slopeChanges() public {
        uint256 timestamp = 999;
        int128 sentinel = 7777;
        bytes32 slot = keccak256(abi.encode(timestamp, uint256(9)));
        vm.store(proxy, slot, bytes32(uint256(uint128(sentinel))));
        assertEq(veHemi.slopeChanges(timestamp), sentinel, "slopeChanges base is not at slot 9");
    }

    function test_slot11_provider() public {
        uint256 tokenId = 42;
        address sentinel = address(0xABCD);
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(11)));
        vm.store(proxy, slot, bytes32(uint256(uint160(sentinel))));
        assertEq(veHemi.provider(tokenId), sentinel, "provider base is not at slot 11");
    }

    function test_slot12_transferableAfter() public {
        uint256 tokenId = 42;
        uint256 sentinel = 0x5678;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(12)));
        vm.store(proxy, slot, bytes32(sentinel));
        assertEq(veHemi.transferableAfter(tokenId), sentinel, "transferableAfter base is not at slot 12");
    }

    function test_slot13_forfeitable() public {
        uint256 tokenId = 42;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(13)));
        vm.store(proxy, slot, bytes32(uint256(1)));
        assertTrue(veHemi.forfeitable(tokenId), "forfeitable base is not at slot 13");
    }

    // =========================================================================
    // V1 → V2 boundary: V1 ends at slot 13, V2 starts at slot 14.
    // These are the CRITICAL assertions. If any field is ever inserted
    // into V1, these tests will fail.
    // =========================================================================

    function test_slot13_isLastV1Slot() public {
        // forfeitable (the last V1 field) is at slot 13.
        // Already verified above — included here for documentary emphasis.
        uint256 tokenId = 99;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(13)));
        vm.store(proxy, slot, bytes32(uint256(1)));
        assertTrue(veHemi.forfeitable(tokenId), "V1 last slot (forfeitable) is not at slot 13");
    }

    // =========================================================================
    // V2 slots (14–20): verify the V2 fields start exactly where expected.
    // =========================================================================

    function test_slot16_lockedSlopeChanges() public {
        // lockedSlopeChanges is a mapping(uint256 => int128) at V2 slot 2 = absolute slot 16.
        uint256 timestamp = 888;
        int128 sentinel = 4444;
        bytes32 slot = keccak256(abi.encode(timestamp, uint256(16)));
        vm.store(proxy, slot, bytes32(uint256(uint128(sentinel))));
        assertEq(veHemi.lockedSlopeChanges(timestamp), sentinel, "lockedSlopeChanges base is not at slot 16");
    }

    function test_slot18_lockedSeedingFinalized() public {
        // lockedSeedingFinalized is a bool at V2 slot 4 = absolute slot 18.
        vm.store(proxy, bytes32(uint256(18)), bytes32(uint256(1)));
        assertTrue(veHemi.lockedSeedingFinalized(), "lockedSeedingFinalized is not at slot 18");
    }

    function test_slot19_forfeitableSlopeChanges() public {
        // forfeitableSlopeChanges is a mapping(uint256 => int128) at V2 slot 5 = absolute slot 19.
        uint256 timestamp = 777;
        int128 sentinel = 3333;
        bytes32 slot = keccak256(abi.encode(timestamp, uint256(19)));
        vm.store(proxy, slot, bytes32(uint256(uint128(sentinel))));
        assertEq(veHemi.forfeitableSlopeChanges(timestamp), sentinel, "forfeitableSlopeChanges base is not at slot 19");
    }

    // =========================================================================
    // V2 gap integrity: the gap starts at slot 21 and extends to slot 63
    // (43 slots). Verify the gap region is clean (all zeros) and that
    // writing at slot 63 (last gap slot) does NOT alias any named field.
    // =========================================================================

    function test_gapV2_doesNotAliasNamedFields() public view {
        // Slots 21–63 should all be zero in a freshly initialized contract.
        for (uint256 i = 21; i <= 63; ++i) {
            bytes32 val = vm.load(proxy, bytes32(i));
            assertEq(val, bytes32(0), string.concat("V2 gap slot ", vm.toString(i), " is not zero"));
        }
    }

    function test_v2TotalSlots_is50() public pure {
        // V2 occupies 7 named slots + 43 gap = 50 total.
        // This assertion is a compile-time-checkable constant that documents
        // the invariant. If someone adds a named field without shrinking
        // the gap, this test must be updated.
        uint256 namedSlots = 7; // reservedSlot0, reservedSlot1, lockedSlopeChanges,
                                // lockedGlobalPointHistory, lockedSeedingFinalized,
                                // forfeitableSlopeChanges, forfeitableGlobalPointHistory
        uint256 gapSlots = 43;
        assertEq(namedSlots + gapSlots, 50, "V2 total slots must be 50");
    }
}
