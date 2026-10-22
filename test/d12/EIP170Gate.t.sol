// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {VeHemi} from "../../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../../src/VeHemiVoteDelegation.sol";
import {VeHemiAragonAdapter} from "../../src/adapter/VeHemiAragonAdapter.sol";
import {PositionFactory} from "../../src/utils/PositionFactory.sol";

/// @title EIP-170 deployability gate, inside `forge test`.
///
/// `forge test` does not enforce EIP-170: an over-limit contract deploys in the
/// test EVM and the suite still passes. These checks make the suite fail
/// instead:
///
///   1. SIZE      every deployable src/ artifact is <= 24,576 B.
///   2. IDENTITY  the runtime code the test EVM actually deployed for the four
///                production non-library contracts (VeHemi, VeHemiVoteDelegation,
///                VeHemiAragonAdapter, PositionFactory; the compile-only
///                VeHemiLayoutProbe is never deployed) has the same length as the
///                artifact that was measured.
///   3. BINDING   a canonical digest over {id, size, sha256(runtime)} of every
///                gated contract equals the digest in
///                test/fixtures/eip170-attestation.json, which
///                scripts/check-eip170.sh writes only when the gate passed. The
///                attestation must be re-stamped with that script after any src
///                change; until then this body is red.
///   4. COVERAGE  the contract set this file iterates must equal the set the
///                script discovered (a set change moves the digest).
contract EIP170GateTest is Test {
    using stdJson for string;

    uint256 internal constant EIP170_LIMIT = 24576;
    string internal constant ATTESTATION = "test/fixtures/eip170-attestation.json";

    /// The gated set, declared independently of the script so that a discovery
    /// bug on either side shows up as a digest mismatch. MUST stay sorted by id
    /// (the digest blob is built in sorted-id order).
    function _ids() internal pure returns (string[9] memory) {
        return [
            "src/VeHemi.sol:VeHemi",
            "src/VeHemiVoteDelegation.sol:VeHemiVoteDelegation",
            "src/adapter/VeHemiAragonAdapter.sol:VeHemiAragonAdapter",
            "src/lib/VeHemiCurveLib.sol:VeHemiCurveLib",
            "src/lib/VeHemiLayout.sol:VeHemiLayoutLib",
            "src/lib/VeHemiLayoutProbe.sol:VeHemiLayoutProbe",
            "src/lib/VeHemiSupplyLib.sol:VeHemiSupplyLib",
            "src/lib/VeHemiTime.sol:VeHemiTime",
            "src/utils/PositionFactory.sol:PositionFactory"
        ];
    }

    function _paths() internal pure returns (string[9] memory) {
        return [
            "out/VeHemi.sol/VeHemi.json",
            "out/VeHemiVoteDelegation.sol/VeHemiVoteDelegation.json",
            "out/VeHemiAragonAdapter.sol/VeHemiAragonAdapter.json",
            "out/VeHemiCurveLib.sol/VeHemiCurveLib.json",
            "out/VeHemiLayout.sol/VeHemiLayoutLib.json",
            "out/VeHemiLayoutProbe.sol/VeHemiLayoutProbe.json",
            "out/VeHemiSupplyLib.sol/VeHemiSupplyLib.json",
            "out/VeHemiTime.sol/VeHemiTime.json",
            "out/PositionFactory.sol/PositionFactory.json"
        ];
    }

    function _runtimeObject(string memory artifactPath) internal view returns (string memory) {
        string memory json = vm.readFile(artifactPath);
        return json.readString(".deployedBytecode.object");
    }

    function _sizeOf(string memory obj) internal pure returns (uint256) {
        uint256 n = bytes(obj).length;
        require(n >= 2, "empty artifact object");
        return (n - 2) / 2; // strip "0x"; library placeholders are address-width, so this is exact
    }

    // ---------------------------------------------------------------- 1. SIZE
    function test_D12_everyDeployableSrcContractFitsEIP170() public {
        string[9] memory ids = _ids();
        string[9] memory paths = _paths();
        uint256 worst = type(uint256).max;
        string memory worstId;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 size = _sizeOf(_runtimeObject(paths[i]));
            emit log_named_uint(string.concat(ids[i], " runtime B"), size);
            assertLe(
                size,
                EIP170_LIMIT,
                string.concat("EIP-170 VIOLATION -- NOT DEPLOYABLE: ", ids[i])
            );
            uint256 margin = EIP170_LIMIT - size;
            if (margin < worst) {
                worst = margin;
                worstId = ids[i];
            }
        }
        emit log_named_uint(string.concat("worst margin B (", worstId, ")"), worst);
    }

    // ------------------------------------------------------------ 2. IDENTITY
    /// The size we gate must be the size of the code the suite actually runs.
    function test_D12_executedRuntimeCodeMatchesGatedArtifact() public {
        VeHemi veHemi = new VeHemi(address(0xBEEF));
        _assertExecutedMatches("src/VeHemi.sol:VeHemi", "out/VeHemi.sol/VeHemi.json", address(veHemi));

        VeHemiVoteDelegation vvd = new VeHemiVoteDelegation(address(veHemi));
        _assertExecutedMatches(
            "src/VeHemiVoteDelegation.sol:VeHemiVoteDelegation",
            "out/VeHemiVoteDelegation.sol/VeHemiVoteDelegation.json",
            address(vvd)
        );

        VeHemiAragonAdapter adapter = new VeHemiAragonAdapter(address(veHemi));
        _assertExecutedMatches(
            "src/adapter/VeHemiAragonAdapter.sol:VeHemiAragonAdapter",
            "out/VeHemiAragonAdapter.sol/VeHemiAragonAdapter.json",
            address(adapter)
        );

        PositionFactory factory = new PositionFactory(address(veHemi), address(this));
        _assertExecutedMatches(
            "src/utils/PositionFactory.sol:PositionFactory",
            "out/PositionFactory.sol/PositionFactory.json",
            address(factory)
        );
    }

    function _assertExecutedMatches(string memory id, string memory path, address deployed) internal {
        uint256 executed = deployed.code.length;
        uint256 gated = _sizeOf(_runtimeObject(path));
        emit log_named_uint(string.concat(id, " executed B"), executed);
        assertEq(executed, gated, string.concat("executed code != gated artifact: ", id));
        assertLe(executed, EIP170_LIMIT, string.concat("executed code exceeds EIP-170: ", id));
    }

    // ---------------------------------------------- 3. BINDING + 4. COVERAGE
    function test_D12_artifactsAreTheOnesTheGateAttested() public {
        string memory att;
        try vm.readFile(ATTESTATION) returns (string memory s) {
            att = s;
        } catch {
            revert(
                "D12: no test/fixtures/eip170-attestation.json. The EIP-170 gate has not "
                "passed on this build. Run ./scripts/check-eip170.sh -- it writes the "
                "attestation ONLY when every src/ contract fits."
            );
        }
        require(bytes(att).length > 0, "D12: empty attestation");

        assertEq(att.readUint(".limit"), EIP170_LIMIT, "attestation limit is not EIP-170");
        assertEq(att.readUint(".contractCount"), _ids().length, "gated-set size drifted from this test");
        emit log_named_string("attested srcTreeSha256", att.readString(".srcTreeSha256"));

        // Rebuild the canonical blob from out/, independently of the script.
        string[9] memory ids = _ids();
        string[9] memory paths = _paths();
        string memory blob = "";
        for (uint256 i = 0; i < ids.length; i++) {
            string memory obj = _runtimeObject(paths[i]);
            blob = string.concat(
                blob,
                ids[i],
                "\n",
                vm.toString(_sizeOf(obj)),
                "\n",
                vm.toString(sha256(bytes(obj))),
                "\n"
            );
        }
        bytes32 recomputed = sha256(bytes(blob));
        emit log_named_bytes32("recomputed digest", recomputed);
        assertEq(
            recomputed,
            att.readBytes32(".digest"),
            "D12: the artifacts in out/ are NOT the ones the EIP-170 gate measured. "
            "Re-run ./scripts/check-eip170.sh; if it fails, this build is not deployable."
        );
    }
}
