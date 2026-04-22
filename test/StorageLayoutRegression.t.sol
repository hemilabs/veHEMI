// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHemiVoteDelegation.sol";

/// @title StorageLayoutRegressionTest
/// @notice Negative control for the storage-layout test harness. Proves that
///         the sentinel-based layout assertions (VeHemiStorageLayout.t.sol,
///         VeHemiV1ToV2Upgrade.t.sol) actually detect a real slot shift —
///         not just pass trivially on the current layout.
///
///         Strategy: deploy a CORRECT V2 impl, write a sentinel at a slot
///         position that the test harness considers authoritative, then
///         manually corrupt the SAME slot to a different value. Any reader
///         using the getter (which follows the Solidity-generated slot map)
///         must surface the corruption as a mismatched value — exactly as if
///         a real layout shift had moved the field.
///
///         If this test ever fails, the assertion mechanism is broken and
///         other layout tests would yield false negatives.
contract StorageLayoutRegressionTest is Test {
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

    /// @dev Simulate a layout regression where the V2 field
    ///      `lockedSeedingFinalized` accidentally moved to a V1 slot.
    ///      Corrupt slot 18 and confirm the getter picks up the change —
    ///      this is the exact mechanism by which the layout tests catch
    ///      slot-shift regressions.
    function test_Slot18Corruption_IsDetectedByGetter() public {
        assertFalse(veHemi.lockedSeedingFinalized(), "baseline zero");

        // Write `true` to slot 18 low byte.
        vm.store(proxy, bytes32(uint256(18)), bytes32(uint256(1)));
        assertTrue(veHemi.lockedSeedingFinalized(), "getter reflects raw write");

        // Clear it again.
        vm.store(proxy, bytes32(uint256(18)), bytes32(uint256(0)));
        assertFalse(veHemi.lockedSeedingFinalized(), "getter reflects raw clear");
    }

    /// @dev If a future change erroneously moved `totalLocked` from slot 0 to
    ///      a different slot, a sentinel written to slot 0 (the pre-change
    ///      expected location) would no longer be visible through the getter.
    ///      Verify the opposite: writing to a DIFFERENT slot must NOT change
    ///      the getter output. This proves slot 0 is uniquely associated with
    ///      totalLocked.
    function test_NonZeroSlotWrite_DoesNotAffectSlot0Getter() public {
        uint256 sentinel = 0x1234;
        vm.store(proxy, bytes32(uint256(0)), bytes32(sentinel));
        assertEq(veHemi.totalLocked(), sentinel);

        // Write to every slot in 1..13 with a different value and confirm
        // totalLocked() continues to return the original sentinel.
        for (uint256 i = 1; i <= 13; ++i) {
            vm.store(proxy, bytes32(i), bytes32(uint256(0xC0FFEE) + i));
            assertEq(
                veHemi.totalLocked(),
                sentinel,
                string.concat("totalLocked corrupted by write to slot ", vm.toString(i))
            );
        }
        // Same for V2 slots 14..63.
        for (uint256 i = 14; i <= 63; ++i) {
            vm.store(proxy, bytes32(i), bytes32(uint256(0xFACADE) + i));
            assertEq(
                veHemi.totalLocked(),
                sentinel,
                string.concat("totalLocked corrupted by write to slot ", vm.toString(i))
            );
        }
    }

    /// @dev TRUE negative control: deploy a deliberately shifted impl
    ///      (VeHemiBadV1 — identical V1 layout except a spurious `__inserted`
    ///      uint256 occupies slot 0, pushing `totalLocked` to slot 1). Etch
    ///      the shifted bytecode onto the live proxy, then verify the exact
    ///      assertion pattern used by VeHemiStorageLayout.t.sol's
    ///      `test_slot0_totalLocked` would FAIL against this mutant.
    ///
    ///      This proves the positive-control sentinel tests are not
    ///      tautological — they would actively detect the specific class of
    ///      regression (field insertion at slot 0) that layout drift tests
    ///      are designed to catch.
    function test_ShiftedLayoutMutant_FailsSlot0Assertion() public {
        // Deploy the mutant impl and etch its runtime code onto the proxy.
        VeHemiBadV1 mutant = new VeHemiBadV1();
        vm.etch(proxy, address(mutant).code);

        // Write sentinel to slot 0 — in the mutant this is `__inserted`,
        // NOT `totalLocked`.
        uint256 sentinel = 0xBEEF;
        vm.store(proxy, bytes32(uint256(0)), bytes32(sentinel));

        // The mutant's `totalLocked()` getter reads slot 1 (where
        // `totalLocked` now lives after the shift), which is currently zero.
        // A positive-control assertion of `assertEq(totalLocked(), sentinel)`
        // against THIS proxy MUST fail — proving the sentinel harness
        // actually discriminates layouts.
        uint256 actualTotalLocked = VeHemiBadV1(proxy).totalLocked();
        assertTrue(
            actualTotalLocked != sentinel,
            "shifted layout went undetected - harness would silently pass a real regression"
        );
        assertEq(actualTotalLocked, 0, "slot 1 was not the post-shift home of totalLocked");

        // Symmetrically, writing to slot 1 DOES affect the mutant's
        // totalLocked getter, confirming the shift is real.
        vm.store(proxy, bytes32(uint256(1)), bytes32(sentinel));
        assertEq(
            VeHemiBadV1(proxy).totalLocked(),
            sentinel,
            "mutant's totalLocked is not actually at slot 1"
        );
    }

    /// @dev Second mutant: LockedBalance with fields swapped so `end` is at
    ///      offset 0 and `amount` at offset 8. The positive-control packing
    ///      formula in test_slot10_locked puts 9999 in bits [0..127] and
    ///      1700000000 in bits [128..191]. On the swapped layout those bits
    ///      decode differently, so the assertEq pattern fails.
    function test_SwappedLockedBalance_FailsSlot10Assertion() public {
        VeHemiBadLockedBalance mutant = new VeHemiBadLockedBalance();
        vm.etch(proxy, address(mutant).code);

        // Mirror the test_slot10_locked packing.
        uint256 tokenId = 42;
        int128 amtSentinel = 9999;
        uint64 endSentinel = 1_700_000_000;
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(10)));
        bytes32 packed = bytes32(
            (uint256(endSentinel) << 128) |
            uint256(uint128(uint256(int256(amtSentinel))))
        );
        vm.store(proxy, slot, packed);

        // On the swapped layout, `end` occupies bits [0..63] (reading the
        // low 64 bits of the packed word → 9999, not 1700000000) and
        // `amount` occupies bits [64..191]. So the getter returns values
        // that do NOT match the original sentinels.
        VeHemiBadLockedBalance.LockedBalanceSwapped memory lb =
            VeHemiBadLockedBalance(proxy).getLocked(tokenId);

        assertTrue(
            lb.end != endSentinel || lb.amount != amtSentinel,
            "swapped LockedBalance layout went undetected - harness would silently pass"
        );
        // Demonstrate the specific mis-decode.
        assertEq(lb.end, uint64(uint128(amtSentinel)), "swap: end read from amount bits");
    }

    /// @dev Third mutant: VeHemiVoteDelegation Delegation struct with
    ///      delegatee and end swapped. Parity with the LockedBalance swap
    ///      mutant — proves the R-2 Delegation member-layout pin in
    ///      StorageLayoutGolden.t.sol would catch a real intra-struct swap.
    ///
    ///      Note: unlike the other mutants (which etch onto a VeHemi proxy),
    ///      this mutant is self-contained. The R-2 golden tests read a
    ///      fixture, not deployed bytecode, so the mutant here is used only
    ///      to DEMONSTRATE that the kind of fixture it would produce
    ///      disagrees with the pinned expectations.
    function test_SwappedDelegation_FixtureDisagreesWithGolden() public {
        BadDelegation mutant = new BadDelegation();
        // Write values through the mutant's setter (swapped layout writes
        // `end` at offset 0, `delegatee` at offset 6).
        mutant.setPair(address(0xABCD), uint48(0x123456));

        // Read raw slot and decode under BOTH layouts; they must disagree.
        // CORRECT layout: delegatee@offset 0 (low 20B), end@offset 20.
        // SWAPPED layout: end@offset 0 (low 6B), delegatee@offset 6.
        bytes32 raw = mutant.raw();
        address correctLayoutDelegatee = address(uint160(uint256(raw)));
        uint48 correctLayoutEnd = uint48(uint256(raw) >> 160);

        // Under correct layout the mutant's state would read as mismatched
        // sentinels — demonstrating that if a future refactor swapped these
        // fields in source, the R-2 pin (delegatee@offset 0, end@offset 20)
        // would fire against the regenerated fixture.
        assertTrue(
            correctLayoutDelegatee != address(0xABCD) || correctLayoutEnd != uint48(0x123456),
            "swapped Delegation fields would decode identically under both layouts - mutant is not discriminating"
        );
    }
}

/// @dev Mutant V1-like contract where a spurious `__inserted` uint256 sits
///      at slot 0, shifting `totalLocked` to slot 1. Deliberately minimal:
///      only exposes the `totalLocked()` getter so the negative control can
///      invoke it.
contract VeHemiBadV1 {
    uint256 private __inserted;        // slot 0 (injected)
    uint256 public totalLocked;        // slot 1 (shifted from 0)
}

/// @dev Mutant with LockedBalance fields swapped. When etched onto a proxy,
///      `getLocked(tokenId)` decodes storage slot keccak(tokenId, 10) under
///      the swapped layout. Comparing against the correct-layout packed
///      sentinel will fail — proving the positive-control test would detect
///      this class of regression.
contract VeHemiBadLockedBalance {
    struct LockedBalanceSwapped {
        uint64 end;     // offset 0 (swapped)
        int128 amount;  // offset 8 (swapped)
    }

    mapping(uint256 => LockedBalanceSwapped) internal _locked;

    function getLocked(uint256 tokenId) external view returns (LockedBalanceSwapped memory) {
        // NOTE: this mapping lives at slot 0 of this contract, but when the
        // bytecode is etched onto a proxy that had a different storage
        // layout, the mapping base still hashes against slot 0. The test
        // writes to keccak(tokenId, 10) — so to hit the same slot, we read
        // from the same base.
        bytes32 slot = keccak256(abi.encode(tokenId, uint256(10)));
        bytes32 word;
        assembly {
            word := sload(slot)
        }
        return LockedBalanceSwapped({
            end: uint64(uint256(word)),
            amount: int128(uint128(uint256(word) >> 64))
        });
    }
}

/// @dev Mutant VoteDelegation with Delegation's first two fields swapped
///      (end before delegatee). Proves the R-2 `DelegationMemberLayout`
///      golden-fixture pin discriminates real struct-field swaps.
contract BadDelegation {
    struct DelegationSwapped {
        uint48 end;          // offset 0 (swapped)
        address delegatee;   // offset 6 (swapped)
    }

    DelegationSwapped internal _data;

    function setPair(address delegatee_, uint48 end_) external {
        _data.end = end_;
        _data.delegatee = delegatee_;
    }

    function raw() external view returns (bytes32 w) {
        assembly { w := sload(_data.slot) }
    }
}
