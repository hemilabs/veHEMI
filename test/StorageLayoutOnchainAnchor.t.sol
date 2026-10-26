// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";

/// @title StorageLayoutOnchainAnchorTest
/// @notice Append-only check against the layout that is already deployed.
///
///         `scripts/check-storage-layouts.sh` and `StorageLayoutGolden.t.sol`
///         assert equality to a fixture that the documented workflow
///         regenerates (`./scripts/update-storage-layouts.sh`); they cannot
///         tell whether a change is safe for the live proxy. This suite
///         anchors to the deployed layouts frozen under
///         `test/fixtures/storage-layouts/onchain/`, extracted from
///         `deployments/hemi/*_Implementation.json`:
///
///           VeHemi impl               0xf1e3aa617e5011793f759092b59d22247e57b84a
///           VeHemiVoteDelegation impl 0xAcAA0d96121C035fC21345551317d66921394128
///
///         RULE ENFORCED: every entry present in the DEPLOYED layout must
///         still exist at the SAME array index with the SAME label, slot,
///         offset and (AST-stripped) type; every struct present in the
///         deployed layout must keep its member count, per-member
///         label/slot/offset/type and `numberOfBytes`. New entries and new
///         structs may be APPENDED. A regeneration cannot launder anything
///         past this, because these files are never regenerated.
///
///         MAINTENANCE: these files are FROZEN. They change exactly once per
///         mainnet implementation upgrade, by re-extracting from the NEW
///         `deployments/hemi/*_Implementation.json` AFTER that implementation
///         is live — never as part of making a red test green.
contract StorageLayoutOnchainAnchorTest is Test {
    string internal veHemiDeployed;
    string internal veHemiCurrent;
    string internal vvdDeployed;
    string internal vvdCurrent;

    function setUp() public {
        veHemiDeployed = vm.readFile("test/fixtures/storage-layouts/onchain/VeHemi.deployed.json");
        veHemiCurrent = vm.readFile("test/fixtures/storage-layouts/VeHemi.json");
        vvdDeployed =
            vm.readFile("test/fixtures/storage-layouts/onchain/VeHemiVoteDelegation.deployed.json");
        vvdCurrent = vm.readFile("test/fixtures/storage-layouts/VeHemiVoteDelegation.json");
    }

    function readEntryLabel(string calldata json, uint256 i) external view returns (string memory) {
        return vm.parseJsonString(json, string.concat(".storage[", vm.toString(i), "].label"));
    }

    function readMemberLabel(string calldata json, string calldata typeKey, uint256 i)
        external
        view
        returns (string memory)
    {
        return vm.parseJsonString(
            json, string.concat(".types.[\"", typeKey, "\"].members[", vm.toString(i), "].label")
        );
    }

    function _countStorageEntries(string memory json) internal returns (uint256) {
        for (uint256 i; i < 256; ++i) {
            try this.readEntryLabel(json, i) {} catch { return i; }
        }
        revert("entry count exceeds 256");
    }

    function _countMembers(string memory json, string memory typeKey) internal returns (uint256) {
        for (uint256 i; i < 64; ++i) {
            try this.readMemberLabel(json, typeKey, i) {} catch { return i; }
        }
        revert("member count exceeds 64");
    }

    function _field(string memory json, uint256 i, string memory f) internal view returns (string memory) {
        return vm.parseJsonString(json, string.concat(".storage[", vm.toString(i), "].", f));
    }

    function _assertAppendOnly(string memory deployed, string memory current, string memory name)
        internal
    {
        uint256 deployedCount = _countStorageEntries(deployed);
        uint256 currentCount = _countStorageEntries(current);

        assertGt(deployedCount, 0, string.concat(name, ": deployed anchor is empty - VACUOUS"));
        assertGe(
            currentCount,
            deployedCount,
            string.concat(
                name,
                ": storage entries were REMOVED relative to the deployed implementation. "
                "A proxy upgrade may only APPEND."
            )
        );

        for (uint256 i; i < deployedCount; ++i) {
            string memory ctx =
                string.concat(name, " deployed entry ", vm.toString(i), " (", _field(deployed, i, "label"), ") ");
            assertEq(
                _field(current, i, "label"),
                _field(deployed, i, "label"),
                string.concat(ctx, "label moved - NOT append-only")
            );
            assertEq(
                _field(current, i, "slot"),
                _field(deployed, i, "slot"),
                string.concat(ctx, "SLOT MOVED - this corrupts the live proxy")
            );
            assertEq(
                vm.parseJsonUint(current, string.concat(".storage[", vm.toString(i), "].offset")),
                vm.parseJsonUint(deployed, string.concat(".storage[", vm.toString(i), "].offset")),
                string.concat(ctx, "offset moved - NOT append-only")
            );
            assertEq(
                _field(current, i, "type"),
                _field(deployed, i, "type"),
                string.concat(ctx, "type changed - NOT append-only")
            );
        }
    }

    function test_VeHemi_FixtureIsAppendOnlyVsDeployedImplementation() public {
        _assertAppendOnly(veHemiDeployed, veHemiCurrent, "VeHemi");
    }

    function test_VeHemiVoteDelegation_FixtureIsAppendOnlyVsDeployedImplementation() public {
        _assertAppendOnly(vvdDeployed, vvdCurrent, "VeHemiVoteDelegation");
    }

    /// @dev The append-only rule applied INSIDE structs. A member appended
    ///      into a struct's free padding leaves every top-level entry at its
    ///      slot and leaves `numberOfBytes` unchanged, so
    ///      `_assertAppendOnly` above cannot see it — but it DOES change how
    ///      the live proxy interprets bytes that the deployed implementation
    ///      never wrote and `delete` never clears.
    ///
    ///      FULLY STRICT: a struct the live proxy already stores keeps its
    ///      member count, every member's label, slot, offset and type, and its
    ///      `numberOfBytes`. There is no padding-append allowance; admitting
    ///      one means amending this function with a written argument that the
    ///      bytes were never a field in any deployed implementation, that 0 is
    ///      the correct legacy value, and that the struct does not grow.
    ///
    ///      NOTE this is strictly narrower than "the compiler says the offsets
    ///      did not move". An assembly write into the same padding produces a
    ///      byte-identical layout and is invisible here and to every other
    ///      layout check.
    function _assertStructUnchanged(
        string memory deployed,
        string memory current,
        string memory typeKey,
        string memory name
    ) internal {
        string memory typePath = string.concat(".types.[\"", typeKey, "\"]");
        assertTrue(
            vm.keyExistsJson(current, typePath),
            string.concat(name, ": struct ", typeKey, " disappeared from the current layout")
        );

        uint256 deployedMembers = _countMembers(deployed, typeKey);
        uint256 currentMembers = _countMembers(current, typeKey);
        assertGt(deployedMembers, 0, string.concat(name, " ", typeKey, ": deployed struct has no members - VACUOUS"));
        assertGe(
            currentMembers,
            deployedMembers,
            string.concat(
                name,
                " ",
                typeKey,
                ": MEMBERS WERE REMOVED from a struct the live proxy already stores. Never allowed."
            )
        );
        assertEq(
            currentMembers,
            deployedMembers,
            string.concat(
                name,
                " ",
                typeKey,
                ": MEMBER COUNT CHANGED vs the deployed implementation. Members may not be "
                "added to a struct that the live proxy already stores. A member appended into "
                "free padding moves neither numberOfBytes nor any existing member offset; once "
                "the fixture is regenerated, the only layout checks that see such a change are "
                "this test and the member-count assertion in StorageLayoutGolden.t.sol."
            )
        );

        for (uint256 i; i < deployedMembers; ++i) {
            string memory memberPath = string.concat(typePath, ".members[", vm.toString(i), "]");
            string memory ctx =
                string.concat(name, " ", typeKey, " member ", vm.toString(i), " ");
            assertEq(
                vm.parseJsonString(current, string.concat(memberPath, ".label")),
                vm.parseJsonString(deployed, string.concat(memberPath, ".label")),
                string.concat(ctx, "label changed")
            );
            assertEq(
                vm.parseJsonString(current, string.concat(memberPath, ".slot")),
                vm.parseJsonString(deployed, string.concat(memberPath, ".slot")),
                string.concat(ctx, "slot changed")
            );
            assertEq(
                vm.parseJsonUint(current, string.concat(memberPath, ".offset")),
                vm.parseJsonUint(deployed, string.concat(memberPath, ".offset")),
                string.concat(ctx, "offset changed")
            );
            assertEq(
                vm.parseJsonString(current, string.concat(memberPath, ".type")),
                vm.parseJsonString(deployed, string.concat(memberPath, ".type")),
                string.concat(ctx, "type changed")
            );
        }

        assertEq(
            vm.parseJsonString(current, string.concat(typePath, ".numberOfBytes")),
            vm.parseJsonString(deployed, string.concat(typePath, ".numberOfBytes")),
            string.concat(name, " ", typeKey, ": numberOfBytes changed vs the deployed implementation")
        );
    }

    function test_VeHemi_DeployedStructShapesAreUnchanged() public {
        _assertStructUnchanged(veHemiDeployed, veHemiCurrent, "t_struct(Point)_storage", "VeHemi");
        _assertStructUnchanged(veHemiDeployed, veHemiCurrent, "t_struct(UserPoint)_storage", "VeHemi");
        _assertStructUnchanged(veHemiDeployed, veHemiCurrent, "t_struct(LockedBalance)_storage", "VeHemi");
        _assertStructUnchanged(veHemiDeployed, veHemiCurrent, "t_struct(LockedPoint)_storage", "VeHemi");
        _assertStructUnchanged(veHemiDeployed, veHemiCurrent, "t_struct(SeedingProgress)_storage", "VeHemi");
    }

    function test_VeHemiVoteDelegation_DeployedStructShapesAreUnchanged() public {
        _assertStructUnchanged(vvdDeployed, vvdCurrent, "t_struct(Delegation)_storage", "VVD");
        _assertStructUnchanged(vvdDeployed, vvdCurrent, "t_struct(DelegateCheckpoint)_storage", "VVD");
        _assertStructUnchanged(vvdDeployed, vvdCurrent, "t_struct(Expiration)_storage", "VVD");
    }

    /// @dev Records what auto-relock appends, so the anchor's own coverage is
    ///      visible rather than implied. The deployed VeHemi layout has 26
    ///      entries; auto-relock appends exactly THREE (slots 64/65 named +
    ///      `__gapV3` at 66) and moves nothing. The delegation layout
    ///      gains THREE (`delegationBookedAt` at slot 100, `legacyDatingUntil`
    ///      at 101, `__gapV4` at 102), also moving nothing. Auto-relock also
    ///      uses `DelegateCheckpoint.fixedBias`, but that member is already
    ///      declared in the deployed implementation, so every VVD struct shape
    ///      is unchanged.
    function test_AutoRelockAppendsExactlyThreeEntriesPerLayoutAndNothingElse() public {
        assertEq(_countStorageEntries(veHemiDeployed), 26, "deployed VeHemi anchor drifted");
        assertEq(_countStorageEntries(veHemiCurrent), 29, "auto-relock must append exactly 3 VeHemi entries");
        assertEq(_field(veHemiCurrent, 26, "slot"), "64", "first appended entry must be at slot 64");
        assertEq(_field(veHemiCurrent, 26, "label"), "autoRelockRemaining");
        // Slot 65 is above the deployed high-water mark (the deployed layout's
        // last entry, `__gapV2`, covers slots 27-63) and has never held live
        // proxy state.
        assertEq(_field(veHemiCurrent, 27, "slot"), "65");
        assertEq(_field(veHemiCurrent, 27, "label"), "autoRelockRefreshedAt");
        assertEq(_field(veHemiCurrent, 28, "slot"), "66", "__gapV3 must start at slot 66");
        assertEq(_field(veHemiCurrent, 28, "label"), "__gapV3");

        // VeHemiDelegationStorageV4 sits on top of V3's reserved block: V3
        // ends at `__gapV3[49]` covering slots 51-99, so V4's first field
        // lands at absolute slot 100 and the deployed prefix (slots 0-99) is
        // untouched.
        assertEq(_countStorageEntries(vvdDeployed), 9, "deployed VVD anchor drifted");
        assertEq(_countStorageEntries(vvdCurrent), 12, "V4 must append exactly 3 VVD entries");
        assertEq(_field(vvdCurrent, 9, "slot"), "100", "delegationBookedAt must land at slot 100");
        assertEq(_field(vvdCurrent, 9, "label"), "delegationBookedAt");
        assertEq(_field(vvdCurrent, 10, "slot"), "101", "legacyDatingUntil must land at slot 101");
        assertEq(_field(vvdCurrent, 10, "label"), "legacyDatingUntil");
        assertEq(_field(vvdCurrent, 11, "slot"), "102", "__gapV4 must start at slot 102");
        assertEq(_field(vvdCurrent, 11, "label"), "__gapV4");
    }

    // ---------------------------------------------------------------------
    // PROVENANCE: the anchor must describe the implementation that is LIVE.
    // ---------------------------------------------------------------------

    /// @notice The two implementation addresses these frozen fixtures were
    ///         extracted from. Changing either is a deliberate act that must
    ///         accompany a re-extraction of the `onchain/` fixtures.
    address internal constant ANCHORED_VEHEMI_IMPL = 0xf1e3AA617E5011793F759092b59d22247E57b84A;
    address internal constant ANCHORED_VVD_IMPL = 0xAcAA0d96121C035fC21345551317d66921394128;

    address internal constant VEHEMI_PROXY = 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89;
    address internal constant VVD_PROXY = 0xBF5b2f370370494B8A4575962512dd3ea7c29e2d;

    /// EIP-1967 implementation slot.
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev THE ANCHOR'S OWN ANCHOR. Every assertion above compares the
    ///      current fixture to `onchain/*.deployed.json`, which is a FILE. If
    ///      mainnet is upgraded and nobody re-extracts those files, the whole
    ///      suite keeps passing while anchoring to an implementation that is
    ///      no longer live — the gate would be green and meaningless.
    ///
    ///      This test closes that loop against the chain: it reads the
    ///      EIP-1967 implementation slot of both live proxies and asserts it
    ///      still equals the address the fixtures were extracted from.
    ///
    ///      SKIPS (does not fail) when `HEMI_RPC_URL` is unset, so offline and
    ///      sandboxed runs are unaffected; a run that sets the variable gets the
    ///      full check against the live head. Read-only: one `eth_getStorageAt`
    ///      per proxy, no transaction is ever broadcast.
    function test_AnchorMatchesTheLiveImplementation() public {
        string memory rpc = vm.envOr("HEMI_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("hemi");

        address liveVeHemiImpl = address(uint160(uint256(vm.load(VEHEMI_PROXY, IMPL_SLOT))));
        address liveVvdImpl = address(uint160(uint256(vm.load(VVD_PROXY, IMPL_SLOT))));

        assertEq(
            liveVeHemiImpl,
            ANCHORED_VEHEMI_IMPL,
            "THE VeHemi ANCHOR IS STALE. Mainnet now runs a different implementation than the one "
            "test/fixtures/storage-layouts/onchain/VeHemi.deployed.json was extracted from. Every "
            "append-only assertion in this file is now measured against the WRONG baseline. "
            "Re-extract the fixture from the NEW deployments/hemi/VeHemi_Implementation.json and "
            "update ANCHORED_VEHEMI_IMPL - do NOT delete this assertion."
        );
        assertEq(
            liveVvdImpl,
            ANCHORED_VVD_IMPL,
            "THE VeHemiVoteDelegation ANCHOR IS STALE. See the VeHemi message above; the same "
            "re-extraction is required for VeHemiVoteDelegation.deployed.json."
        );
    }
}
