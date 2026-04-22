// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemiVoteDelegation.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title VeHemiVoteDelegationUpgradeTest
/// @notice Sentinel-based upgrade regression test for VeHemiVoteDelegation.
///         Mirrors the VeHemiV1ToV2Upgrade.t.sol approach: populate every
///         storage slot with a distinct sentinel, upgrade to a fresh impl
///         via ERC-1967 slot write, verify bit-for-bit preservation.
///
///         This closes the coverage gap where the Aragon-adapter addition
///         (slots 4 = autoDelegate, 5 = trustedAdapter) had no upgrade
///         regression test. The __gap[44] region is also verified.
contract VeHemiVoteDelegationUpgradeTest is Test {
    VeHemiVoteDelegation impl1;
    VeHemiVoteDelegation impl2;
    address proxy;
    VeHemiVoteDelegation delegation;

    // Dummy VeHemi address — the delegation contract holds it as immutable.
    address constant VE_HEMI = address(0xABCD);

    // Sentinel keys.
    uint256 constant TEST_TOKEN_ID = 12345;
    address constant TEST_ACCOUNT = address(0xA0A0);
    address constant TEST_DELEGATEE = address(0xD0D0);
    address constant TEST_ADAPTER = address(0xAAAABBBBCCCC);
    address constant TEST_AUTO_DELEGATE = address(0xDEADBEEF);

    function setUp() public {
        impl1 = new VeHemiVoteDelegation(VE_HEMI);
        impl2 = new VeHemiVoteDelegation(VE_HEMI);

        ERC1967Proxy p = new ERC1967Proxy(
            address(impl1),
            abi.encodeWithSelector(VeHemiVoteDelegation.initialize.selector)
        );
        proxy = address(p);
        delegation = VeHemiVoteDelegation(proxy);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    // Slot 0 Delegation struct sentinels (first slot packs {address delegatee, uint48 end}).
    address constant DELEGATION_DELEGATEE = address(0xD0D01234);
    uint48 constant DELEGATION_END = 0xEEEEEEEEEE;
    // Slot 2 Expiration struct sentinels ({uint96 bias, uint96 amount, uint64 slope} packed in 1 slot).
    uint96 constant EXPIRATION_BIAS = 0xBBBBBB;
    uint96 constant EXPIRATION_AMOUNT = 0xAAAAAA;
    uint64 constant EXPIRATION_SLOPE = 0x99999999;
    // Slot 3 nonces sentinel.
    uint256 constant NONCE_SENTINEL = 0xD3;

    function _writeSentinels() internal {
        // Slot 0 (delegations mapping → Delegation struct, 2 slots). Build the
        // packed first word from independent sentinels and write. The upgrade
        // regression reads BACK through the public `delegations(uint256)`
        // getter (which ABI-decodes the struct), so any intra-struct field
        // swap or width change would cause the read to return something
        // other than the sentinels — this is a REAL layout binding, not a
        // raw-bytes round-trip.
        //
        // Packing (slot 0): address at offset 0 (20B), uint48 at offset 20 (6B).
        // Slot 1 {bias, amount, slope} is LEFT ZERO to keep the test hermetic;
        // the intra-slot-1 layout is covered by
        // `test_VeHemiVoteDelegation_DelegationMemberLayout` in
        // StorageLayoutGolden.t.sol.
        bytes32 delegationSlot0 = bytes32(
            (uint256(DELEGATION_END) << 160) | uint256(uint160(DELEGATION_DELEGATEE))
        );
        bytes32 base0 = keccak256(abi.encode(TEST_TOKEN_ID, uint256(0)));
        vm.store(proxy, base0, delegationSlot0);

        // Slot 1 (delegateCheckpoints mapping → dynamic array): write the
        // length slot directly. The public getter `delegateCheckpoints(addr, idx)`
        // reads ARRAY ELEMENTS, not the length; there is no getter that
        // surfaces the length slot, so we verify via vm.load in _assertSentinels.
        // This slot's layout binding is covered statically by
        // `test_VeHemiVoteDelegation_AllSlotsAtExpectedPositions` in Golden.
        bytes32 base1 = keccak256(abi.encode(TEST_ACCOUNT, uint256(1)));
        vm.store(proxy, base1, bytes32(uint256(0xD1)));

        // Slot 2 (expiredDelegations → nested mapping → Expiration struct, 1 slot).
        // Packing: uint96 bias @0, uint96 amount @12, uint64 slope @24.
        // Public getter `expiredDelegations(addr, uint256)` ABI-decodes the
        // struct so we read back through it.
        bytes32 expirationSlot = bytes32(
            (uint256(EXPIRATION_SLOPE) << 192) |
            (uint256(EXPIRATION_AMOUNT) << 96) |
            uint256(EXPIRATION_BIAS)
        );
        bytes32 base2Outer = keccak256(abi.encode(TEST_ACCOUNT, uint256(2)));
        bytes32 base2Inner = keccak256(abi.encode(uint256(777), base2Outer));
        vm.store(proxy, base2Inner, expirationSlot);

        // Slot 3 (nonces mapping → uint256): public `nonces(addr)` getter.
        bytes32 base3 = keccak256(abi.encode(TEST_ACCOUNT, uint256(3)));
        vm.store(proxy, base3, bytes32(NONCE_SENTINEL));

        // Slot 4 (autoDelegate mapping → address): public getter.
        bytes32 base4 = keccak256(abi.encode(TEST_ACCOUNT, uint256(4)));
        vm.store(proxy, base4, bytes32(uint256(uint160(TEST_AUTO_DELEGATE))));

        // Slot 5 (trustedAdapter address): direct slot, public getter.
        vm.store(proxy, bytes32(uint256(5)), bytes32(uint256(uint160(TEST_ADAPTER))));
    }

    function _assertSentinels() internal view {
        // Slot 0: read via `delegations(tokenId)` — public getter returns the
        // full Delegation tuple. A field reorder within the struct would
        // cause at least one field to return something other than its
        // sentinel, failing this assertion. Far stronger than a raw vm.load
        // round-trip at the same slot.
        (address delegatee, uint48 end, uint96 bias, uint96 amount, uint64 slope) =
            delegation.delegations(TEST_TOKEN_ID);
        assertEq(delegatee, DELEGATION_DELEGATEE, "slot 0 Delegation.delegatee corrupted");
        assertEq(uint256(end), uint256(DELEGATION_END), "slot 0 Delegation.end corrupted");
        // Slot 1 of the Delegation struct was not written, so these must be zero.
        assertEq(uint256(bias), 0, "slot 0 Delegation.bias unexpectedly set");
        assertEq(uint256(amount), 0, "slot 0 Delegation.amount unexpectedly set");
        assertEq(uint256(slope), 0, "slot 0 Delegation.slope unexpectedly set");

        // Slot 1: no getter for the array length — verify via raw vm.load.
        bytes32 base1 = keccak256(abi.encode(TEST_ACCOUNT, uint256(1)));
        assertEq(vm.load(proxy, base1), bytes32(uint256(0xD1)), "slot 1 delegateCheckpoints length corrupted");

        // Slot 2: read via `expiredDelegations(addr, sixDays)` — public getter.
        (uint96 expBias, uint96 expAmount, uint64 expSlope) =
            delegation.expiredDelegations(TEST_ACCOUNT, uint256(777));
        assertEq(uint256(expBias), uint256(EXPIRATION_BIAS), "slot 2 Expiration.bias corrupted");
        assertEq(uint256(expAmount), uint256(EXPIRATION_AMOUNT), "slot 2 Expiration.amount corrupted");
        assertEq(uint256(expSlope), uint256(EXPIRATION_SLOPE), "slot 2 Expiration.slope corrupted");

        // Slot 3: public `nonces(addr)` getter.
        assertEq(delegation.nonces(TEST_ACCOUNT), NONCE_SENTINEL, "slot 3 nonces corrupted");

        assertEq(delegation.autoDelegate(TEST_ACCOUNT), TEST_AUTO_DELEGATE, "slot 4 autoDelegate corrupted");
        assertEq(delegation.trustedAdapter(), TEST_ADAPTER, "slot 5 trustedAdapter corrupted");
    }

    function _upgradeTo(address newImpl) internal {
        bytes32 IMPL_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        vm.store(proxy, IMPL_SLOT, bytes32(uint256(uint160(newImpl))));
    }

    // =========================================================================
    // Tests
    // =========================================================================

    function test_AllSlotsSurviveUpgrade() public {
        _writeSentinels();
        _upgradeTo(address(impl2));
        _assertSentinels();
    }

    /// @dev The __gap[44] region occupies slots 6..49 — a fixed-size
    ///      `uint256[44]` at base slot 6 uses slots [6, 6+44-1] = [6, 49].
    ///      Verify every gap slot remains zero pre and post upgrade. CRITICAL:
    ///      slot 6 is the first gap slot (not slot 7); an off-by-one here
    ///      would miss regressions that consume __gap[0].
    function test_GapSlotsRemainZeroAfterUpgrade() public {
        _writeSentinels();
        for (uint256 i = 6; i <= 49; ++i) {
            assertEq(vm.load(proxy, bytes32(i)), bytes32(0), "gap slot dirty pre-upgrade");
        }
        _upgradeTo(address(impl2));
        for (uint256 i = 6; i <= 49; ++i) {
            assertEq(
                vm.load(proxy, bytes32(i)),
                bytes32(0),
                string.concat("gap slot ", vm.toString(i), " corrupted by upgrade")
            );
        }
    }

    function test_UpgradeDoesNotResetInitializedFlag() public {
        _upgradeTo(address(impl2));
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        delegation.initialize();
    }

    /// @dev Front-run defense: after an impl swap, no caller should be able
    ///      to re-initialize the delegation contract (no hijacking vector).
    function test_UpgradeThenInitializeFrontRun_Reverts() public {
        _upgradeTo(address(impl2));

        address[] memory attackers = new address[](3);
        attackers[0] = makeAddr("attacker1");
        attackers[1] = makeAddr("attacker2");
        attackers[2] = address(this);

        for (uint256 i; i < attackers.length; ++i) {
            vm.prank(attackers[i]);
            vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
            delegation.initialize();
        }
    }

    /// @dev Round-trip: impl1 → impl2 → impl1. Sentinels must survive both
    ///      upgrades, and the gap must stay zero throughout.
    function test_UpgradeRoundTripPreservesAllSlots() public {
        _writeSentinels();

        _upgradeTo(address(impl2));
        _assertSentinels();

        _upgradeTo(address(impl1));
        _assertSentinels();

        for (uint256 i = 6; i <= 49; ++i) {
            assertEq(vm.load(proxy, bytes32(i)), bytes32(0), "gap corrupted after round-trip");
        }
    }
}
