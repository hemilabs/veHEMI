// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";

/// @title StorageLayoutCompiledParityTest
/// @notice Diffs each committed storage-layout fixture against the artifact
///         solc produced under `out/`: `label` / `slot` / `offset` and the
///         entry count for every top-level entry, and member `label` / `slot` /
///         `offset` and the member count for every struct. Without it, a layout
///         test that reads only the fixture passes against a stale fixture.
///
///         `.type` is not compared: the artifact carries raw AST-id identifiers
///         (`t_struct(Point)129_storage`) while the fixture is normalized by
///         `scripts/_normalize-storage-layout.sh`. Type identity stays covered
///         by the type pins in StorageLayoutGolden.t.sol and by
///         `scripts/check-storage-layouts.sh`.
///
///         An artifact without `.storageLayout` would make both sides read zero
///         entries, so the top-level check first asserts `.storageLayout`
///         exists, `test_ParityIsNotVacuous` asserts both sides are non-empty
///         for the two proxied contracts, and the struct check refuses a
///         fixture struct with no members; `foundry.toml` sets
///         `extra_output = ["storageLayout"]`.
contract StorageLayoutCompiledParityTest is Test {
    struct Target {
        string name;
        string fixturePath;
        string artifactPath;
    }

    function _targets() internal pure returns (Target[3] memory t) {
        t[0] = Target(
            "VeHemi",
            "test/fixtures/storage-layouts/VeHemi.json",
            "out/VeHemi.sol/VeHemi.json"
        );
        t[1] = Target(
            "VeHemiVoteDelegation",
            "test/fixtures/storage-layouts/VeHemiVoteDelegation.json",
            "out/VeHemiVoteDelegation.sol/VeHemiVoteDelegation.json"
        );
        t[2] = Target(
            "VeHemiAragonAdapter",
            "test/fixtures/storage-layouts/VeHemiAragonAdapter.json",
            "out/VeHemiAragonAdapter.sol/VeHemiAragonAdapter.json"
        );
    }

    // ─── probes (external so they can be try/caught) ────────────────────────

    function probeEntry(string calldata json, string calldata base, uint256 i)
        external
        view
        returns (string memory)
    {
        return vm.parseJsonString(json, string.concat(base, "[", vm.toString(i), "].label"));
    }

    function probeStructMember(string calldata json, string calldata typePath, uint256 i)
        external
        view
        returns (string memory)
    {
        return vm.parseJsonString(json, string.concat(typePath, ".members[", vm.toString(i), "].label"));
    }

    function _count(string memory json, string memory base) internal returns (uint256) {
        for (uint256 i; i < 256; ++i) {
            try this.probeEntry(json, base, i) {
                // exists
            } catch {
                return i;
            }
        }
        revert("storage entry count exceeds 256");
    }

    function _countMembers(string memory json, string memory typePath) internal returns (uint256) {
        for (uint256 i; i < 64; ++i) {
            try this.probeStructMember(json, typePath, i) {
                // exists
            } catch {
                return i;
            }
        }
        revert("struct member count exceeds 64");
    }

    // ─── GATE 1: top-level entries ──────────────────────────────────────────

    function _assertTopLevelParity(Target memory t) internal {
        string memory fixture = vm.readFile(t.fixturePath);
        string memory artifact = vm.readFile(t.artifactPath);

        assertTrue(
            vm.keyExistsJson(artifact, ".storageLayout"),
            string.concat(
                t.name,
                ": artifact has no .storageLayout - this suite would pass VACUOUSLY. "
                "Set extra_output = [\"storageLayout\"] in foundry.toml and rebuild."
            )
        );

        uint256 fixtureCount = _count(fixture, ".storage");
        uint256 artifactCount = _count(artifact, ".storageLayout.storage");

        assertEq(
            artifactCount,
            fixtureCount,
            string.concat(
                t.name,
                ": the COMPILED layout has a different number of storage entries than the "
                "committed fixture. The fixture is STALE. Run ./scripts/update-storage-layouts.sh "
                "and review the diff for append-only-ness."
            )
        );

        for (uint256 i; i < fixtureCount; ++i) {
            string memory fi = string.concat(".storage[", vm.toString(i), "]");
            string memory ai = string.concat(".storageLayout.storage[", vm.toString(i), "]");
            string memory ctx = string.concat(t.name, " entry ", vm.toString(i), " ");
            assertEq(
                vm.parseJsonString(artifact, string.concat(ai, ".label")),
                vm.parseJsonString(fixture, string.concat(fi, ".label")),
                string.concat(ctx, "label drifted from fixture")
            );
            assertEq(
                vm.parseJsonString(artifact, string.concat(ai, ".slot")),
                vm.parseJsonString(fixture, string.concat(fi, ".slot")),
                string.concat(ctx, "slot drifted from fixture")
            );
            assertEq(
                vm.parseJsonUint(artifact, string.concat(ai, ".offset")),
                vm.parseJsonUint(fixture, string.concat(fi, ".offset")),
                string.concat(ctx, "offset drifted from fixture")
            );
        }
    }

    function test_TopLevelLayoutMatchesCompiledArtifact() public {
        Target[3] memory ts = _targets();
        for (uint256 i; i < ts.length; ++i) {
            _assertTopLevelParity(ts[i]);
        }
    }

    /// @dev The parity check above is only meaningful if both sides are
    ///      non-empty for the two proxied contracts. (The adapter is
    ///      legitimately empty — that is asserted separately.)
    function test_ParityIsNotVacuous() public {
        Target[3] memory ts = _targets();
        assertGt(_count(vm.readFile(ts[0].fixturePath), ".storage"), 0, "VeHemi fixture is empty");
        assertGt(
            _count(vm.readFile(ts[0].artifactPath), ".storageLayout.storage"),
            0,
            "VeHemi artifact layout is empty - the parity test would pass on nothing"
        );
        assertGt(_count(vm.readFile(ts[1].fixturePath), ".storage"), 0, "VVD fixture is empty");
        assertGt(
            _count(vm.readFile(ts[1].artifactPath), ".storageLayout.storage"),
            0,
            "VVD artifact layout is empty - the parity test would pass on nothing"
        );
        assertEq(
            _count(vm.readFile(ts[2].artifactPath), ".storageLayout.storage"),
            0,
            "VeHemiAragonAdapter must remain stateless"
        );
    }

    // ─── GATE 2: struct shapes ──────────────────────────────────────────────
    //
    // A member appended into a struct's FREE PADDING moves no top-level entry,
    // no member offset and no `numberOfBytes` — Gate 1 cannot see it. Compare
    // member COUNT and per-member label/slot/offset against the compiler.
    //
    // Type keys differ between the two files (the artifact keeps AST ids), so
    // the artifact-side key is resolved by scanning `.storageLayout.types` for
    // the key whose `.label` matches the fixture type's `.label` — labels
    // ("struct IVeHemi.Point") carry no AST id.

    function probeTypeKeyByLabel(string calldata artifact, string calldata wantLabel)
        external
        view
        returns (string memory)
    {
        string[] memory keys = vm.parseJsonKeys(artifact, ".storageLayout.types");
        for (uint256 i; i < keys.length; ++i) {
            string memory lbl = vm.parseJsonString(
                artifact, string.concat(".storageLayout.types.[\"", keys[i], "\"].label")
            );
            if (keccak256(bytes(lbl)) == keccak256(bytes(wantLabel))) {
                return string.concat(".storageLayout.types.[\"", keys[i], "\"]");
            }
        }
        revert(string.concat("no compiled type with label ", wantLabel));
    }

    function _assertStructParity(
        string memory artifact,
        string memory fixture,
        string memory fixtureTypeKey,
        string memory ctxName
    ) internal {
        string memory fixturePath = string.concat(".types.[\"", fixtureTypeKey, "\"]");
        string memory wantLabel = vm.parseJsonString(fixture, string.concat(fixturePath, ".label"));
        string memory artifactPath = this.probeTypeKeyByLabel(artifact, wantLabel);

        uint256 fixtureMembers = _countMembers(fixture, fixturePath);
        uint256 artifactMembers = _countMembers(artifact, artifactPath);

        assertGt(fixtureMembers, 0, string.concat(ctxName, ": fixture struct has no members - vacuous"));
        assertEq(
            artifactMembers,
            fixtureMembers,
            string.concat(
                ctxName,
                ": the COMPILED struct has a different member count than the committed "
                "fixture. A member was added or removed and the fixture was not regenerated. "
                "This class of change moves NEITHER numberOfBytes NOR any existing member "
                "offset, so no size or offset check sees it; scripts/check-storage-layouts.sh, "
                "which diffs the whole compiled layout against the fixture, does."
            )
        );

        for (uint256 i; i < fixtureMembers; ++i) {
            string memory fi = string.concat(fixturePath, ".members[", vm.toString(i), "]");
            string memory ai = string.concat(artifactPath, ".members[", vm.toString(i), "]");
            string memory ctx = string.concat(ctxName, " member ", vm.toString(i), " ");
            assertEq(
                vm.parseJsonString(artifact, string.concat(ai, ".label")),
                vm.parseJsonString(fixture, string.concat(fi, ".label")),
                string.concat(ctx, "label drifted")
            );
            assertEq(
                vm.parseJsonString(artifact, string.concat(ai, ".slot")),
                vm.parseJsonString(fixture, string.concat(fi, ".slot")),
                string.concat(ctx, "slot drifted")
            );
            assertEq(
                vm.parseJsonUint(artifact, string.concat(ai, ".offset")),
                vm.parseJsonUint(fixture, string.concat(fi, ".offset")),
                string.concat(ctx, "offset drifted")
            );
        }

        assertEq(
            vm.parseJsonString(artifact, string.concat(artifactPath, ".numberOfBytes")),
            vm.parseJsonString(fixture, string.concat(fixturePath, ".numberOfBytes")),
            string.concat(ctxName, ": numberOfBytes drifted from the compiled struct")
        );
    }

    function test_VeHemiStructShapesMatchCompiledArtifact() public {
        string memory fixture = vm.readFile("test/fixtures/storage-layouts/VeHemi.json");
        string memory artifact = vm.readFile("out/VeHemi.sol/VeHemi.json");
        _assertStructParity(artifact, fixture, "t_struct(Point)_storage", "Point");
        _assertStructParity(artifact, fixture, "t_struct(UserPoint)_storage", "UserPoint");
        _assertStructParity(artifact, fixture, "t_struct(LockedBalance)_storage", "LockedBalance");
        _assertStructParity(artifact, fixture, "t_struct(LockedPoint)_storage", "LockedPoint");
        _assertStructParity(artifact, fixture, "t_struct(SeedingProgress)_storage", "SeedingProgress");
    }

    function test_DelegationStructShapesMatchCompiledArtifact() public {
        string memory fixture = vm.readFile("test/fixtures/storage-layouts/VeHemiVoteDelegation.json");
        string memory artifact = vm.readFile("out/VeHemiVoteDelegation.sol/VeHemiVoteDelegation.json");
        _assertStructParity(artifact, fixture, "t_struct(Delegation)_storage", "Delegation");
        _assertStructParity(artifact, fixture, "t_struct(DelegateCheckpoint)_storage", "DelegateCheckpoint");
        _assertStructParity(artifact, fixture, "t_struct(Expiration)_storage", "Expiration");
    }
}
