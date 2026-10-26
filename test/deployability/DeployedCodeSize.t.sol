// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../../src/VeHemi.sol";
import "../../src/VeHemiVoteDelegation.sol";
import "../../src/adapter/VeHemiAragonAdapter.sol";
import "../mocks/MockERC20.sol";

/// @notice Deployability of the production contracts, measured as `address.code.length`
///         on a real CREATE: every runtime fits EIP-170 with the CI's 64-byte warning
///         margin, and the VeHemi and VeHemiVoteDelegation init code fits EIP-3860.
///         The two linked libraries are
///         CREATE'd from their own creation code, because the CI size step only scans
///         `contract` declarations and never sees a library.
contract DeployedCodeSizeTest is Test {
    uint256 internal constant EIP170_LIMIT = 24_576;
    uint256 internal constant CI_WARN = EIP170_LIMIT - 64; // 24_512, the CI size step's warn line

    function _assertRuntimeFits(string memory name, address deployed) internal returns (uint256 n) {
        n = deployed.code.length;
        emit log_named_uint(string.concat("RUNTIME ", name), n);
        assertGt(n, 0, string.concat(name, " did not deploy (CREATE returned 0)"));
        assertLe(n, EIP170_LIMIT, string.concat(name, " over EIP-170"));
        assertLe(n, CI_WARN, string.concat(name, " over the CI warn line 24512"));
    }

    function test_contractsFitEIP170AfterCreate() public {
        MockERC20 hemi = new MockERC20("HEMI", "HEMI", 18);
        VeHemi veHemi = new VeHemi(address(hemi));
        VeHemiVoteDelegation delegation = new VeHemiVoteDelegation(address(veHemi));
        VeHemiAragonAdapter adapter = new VeHemiAragonAdapter(address(veHemi));
        _assertRuntimeFits("VeHemi", address(veHemi));
        _assertRuntimeFits("VeHemiVoteDelegation", address(delegation));
        _assertRuntimeFits("VeHemiAragonAdapter", address(adapter));
    }

    /// @notice The two linked libraries, which the CI size step does not cover.
    function test_librariesFitEIP170AfterCreate() public {
        _assertRuntimeFits("VeHemiCurveLib", deployCode("VeHemiCurveLib.sol:VeHemiCurveLib"));
        _assertRuntimeFits("VeHemiSupplyLib", deployCode("VeHemiSupplyLib.sol:VeHemiSupplyLib"));
    }

    /// @notice EIP-3860 init-code limit (49,152 bytes) on VeHemi and VeHemiVoteDelegation.
    function test_initCodeFitsEIP3860() public {
        assertLe(type(VeHemi).creationCode.length, 49_152, "VeHemi init-code over EIP-3860");
        assertLe(type(VeHemiVoteDelegation).creationCode.length, 49_152, "VVD init-code over EIP-3860");
    }
}
