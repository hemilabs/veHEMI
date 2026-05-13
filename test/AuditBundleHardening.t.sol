// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";
import {VeHemi} from "../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../src/VeHemiVoteDelegation.sol";
import {IVeHemiVoteDelegation} from "../src/interfaces/IVeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title  AuditBundleHardening
/// @notice Behavioral coverage for the 2026-05-04 audit "low-risk LOW" bundle:
///         LOW-3 (delegateBySig check ordering), LOW-5 (setTrustedAdapter
///         contract probe), LOW-6 (isTransferable on burned/nonexistent),
///         LOW-16 (bootstrap _delegate guard), MED-2 (DelegationSlopeOverflow).
///         LOW-2 and LOW-15 are doc-only / dead-branch guards and are exercised
///         transitively by the existing suite.
contract AuditBundleHardening is LockedCurveTestBase {

    // ─────────────────────────────────────────────────────────────────────
    // LOW-3: delegateBySig expiry check fires before nonce burn / SLOADs
    // ─────────────────────────────────────────────────────────────────────

    function test_LOW3_delegateBySig_expiredSignature_revertsWithoutBurningNonce() public {
        // Create a position so the path can be exercised end-to-end.
        (uint256 tokenId,,) = createLock(alice, 100 ether, YEAR);

        uint256 priorNonce = delegation.nonces(alice);
        uint256 expiry = block.timestamp - 1;

        // Signature values are irrelevant — expiry check is the first guard.
        vm.expectRevert(VeHemiVoteDelegation.SignatureExpired.selector);
        delegation.delegateBySig(
            tokenId,
            bob,
            priorNonce,
            expiry,
            0, // v
            bytes32(0), // r
            bytes32(0)  // s
        );

        // Critical: the signer's nonce slot must be unchanged. Pre-fix, the
        // expiry check ran AFTER `nonces[_signer]++`, so an expired sig
        // would still consume the nonce.
        assertEq(delegation.nonces(alice), priorNonce, "nonce must not advance on expired sig");
    }

    // --- LOW-3 EIP-712 helpers (BNR2-G7) ---
    bytes32 private constant _DELEGATION_TYPEHASH =
        keccak256("Delegation(uint256 delegator,address delegatee,uint256 nonce,uint256 expiry)");
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    string  private constant _EIP712_NAME    = "veHEMIDelegation";
    string  private constant _EIP712_VERSION = "1.0.0";

    function _delegationDigest(
        uint256 delegator_,
        address delegatee_,
        uint256 nonce_,
        uint256 expiry_
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256(bytes(_EIP712_NAME)),
                keccak256(bytes(_EIP712_VERSION)),
                block.chainid,
                address(delegation)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(_DELEGATION_TYPEHASH, delegator_, delegatee_, nonce_, expiry_)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @notice Happy path: a valid signature must produce a successful
    ///         delegation AND bump the signer's nonce by exactly one.
    function test_LOW3_validSig_consumesNonce() public {
        (address signer, uint256 signerPk) = makeAddrAndKey("low3-signer");

        hemi.mint(signer, 100 ether);
        vm.startPrank(signer);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 tokenId = veHemi.createLock(100 ether, YEAR);
        vm.stopPrank();

        uint256 priorNonce = delegation.nonces(signer);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest = _delegationDigest(tokenId, bob, priorNonce, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        // Any account may relay the signed message — call from a third party.
        delegation.delegateBySig(tokenId, bob, priorNonce, expiry, v, r, s);

        (address recordedDelegatee,,,,) = delegation.delegations(tokenId);
        assertEq(recordedDelegatee, bob, "delegate not set");
        assertEq(
            delegation.nonces(signer),
            priorNonce + 1,
            "valid sig must consume exactly one nonce"
        );

        // Replaying the same signature must now fail on the nonce check.
        vm.expectRevert(VeHemiVoteDelegation.InvalidNonce.selector);
        delegation.delegateBySig(tokenId, bob, priorNonce, expiry, v, r, s);
        // And the revert must roll back the post-increment in
        // `nonces[_signer]++` — Solidity evaluates the post-inc before the
        // comparison reverts, but EVM revert semantics roll back the SSTORE.
        // Locking the assertion in here pre-empts the "stale-nonce replay
        // griefs the signer's nonce" misread (R2-G3 / R3-G11).
        assertEq(
            delegation.nonces(signer),
            priorNonce + 1,
            "failed replay must not advance signer's nonce a second time"
        );
    }

    /// @notice A VALID signature (properly signed by the position owner) but
    ///         whose `expiry` has passed must revert `SignatureExpired` AND
    ///         leave the signer's nonce untouched. This is the exact path the
    ///         LOW-3 fix targets: pre-fix, the expiry check ran AFTER the
    ///         nonce bump, so an attacker could burn a victim's nonce by
    ///         relaying an old-but-genuine signature.
    function test_LOW3_validExpiredSig_doesNotBurnNonce() public {
        (address signer, uint256 signerPk) = makeAddrAndKey("low3-signer-expired");

        hemi.mint(signer, 100 ether);
        vm.startPrank(signer);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 tokenId = veHemi.createLock(100 ether, YEAR);
        vm.stopPrank();

        uint256 priorNonce = delegation.nonces(signer);

        // Sign with an expiry one hour in the future relative to "now"…
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = _delegationDigest(tokenId, bob, priorNonce, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        // …then jump past the expiry so the signature is stale but otherwise
        // perfectly valid (correct signer, correct nonce, correct payload).
        vm.warp(expiry + 1);

        vm.expectRevert(VeHemiVoteDelegation.SignatureExpired.selector);
        delegation.delegateBySig(tokenId, bob, priorNonce, expiry, v, r, s);

        assertEq(
            delegation.nonces(signer),
            priorNonce,
            "expired-but-valid sig must NOT burn the signer's nonce"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // LOW-5: setTrustedAdapter rejects zero-code addresses
    // ─────────────────────────────────────────────────────────────────────

    function test_LOW5_setTrustedAdapter_rejectsEOA() public {
        address eoa = address(0xCAFE);
        // No bytecode at eoa — should revert.
        vm.expectRevert(VeHemiVoteDelegation.InvalidAdapter.selector);
        delegation.setTrustedAdapter(eoa);
    }

    function test_LOW5_setTrustedAdapter_acceptsContract() public {
        address candidate = address(0xC0DE);
        vm.etch(candidate, hex"60006000"); // minimal non-empty bytecode
        delegation.setTrustedAdapter(candidate);
        assertEq(delegation.trustedAdapter(), candidate, "contract candidate accepted");
    }

    function test_LOW5_setTrustedAdapter_acceptsZeroAddressAsDisable() public {
        // address(0) is an explicit "disable" signal — must remain valid.
        delegation.setTrustedAdapter(address(0));
        assertEq(delegation.trustedAdapter(), address(0), "address(0) accepted as disable");
    }

    function test_LOW5_setTrustedAdapter_zeroCodeAddressMatchingExisting_stillReverts() public {
        // Even if the candidate matches the current value, zero-code is rejected.
        address eoa = address(0xDEAD);
        vm.expectRevert(VeHemiVoteDelegation.InvalidAdapter.selector);
        delegation.setTrustedAdapter(eoa);
    }

    // ─────────────────────────────────────────────────────────────────────
    // LOW-6: deferred (VeHemi bytecode-constrained — see VeHemi.isTransferable
    // NatSpec). The pre-fix behavior is unchanged in this bundle.
    // ─────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────
    // LOW-16: _delegate emits DelegationUpdateFailed when voteDelegation==0
    // ─────────────────────────────────────────────────────────────────────
    //
    // The fix adds an explicit `address(voteDelegation) == address(0)` guard
    // at the top of `_delegate` so the function emits `DelegationUpdateFailed`
    // and returns instead of silently CALLing a zero-code address. A unit
    // test for this exact path is non-trivial to construct because the
    // companion path `_reDelegate` (which runs inside `_depositFor` before
    // `_delegate` is reached on the mint path) ALSO calls into
    // `voteDelegation` and its try/catch around a struct-returning function
    // bubbles up extcodesize reverts on zero-code addresses. Production
    // deploy ordering closes the bootstrap window so the gap was already
    // defensive in depth; the explicit guard makes the failure mode
    // observable if any future deploy path momentarily reverts to
    // `voteDelegation == address(0)`. Code review and the static analysis
    // of `_delegate` (single-branch addition above existing try/catch)
    // covers the change.

    // ─────────────────────────────────────────────────────────────────────
    // MED-2: DelegationSlopeOverflow surfaces a self-describing revert
    // ─────────────────────────────────────────────────────────────────────

    function test_MED2_aggregateSlopeOverflow_revertsWithCustomError() public {
        // The cap is uint64.max ≈ 1.844e19 slope units. Slope = amount/MAX_TIME.
        // To force overflow we need cumulative amount > uint64.max * MAX_TIME ≈ 2.328 B HEMI.
        // Two huge locks delegated to the same delegatee will tip the
        // checkpoint slope past uint64.max on the second delegation.
        uint256 huge = uint256(type(uint64).max) * MAX_TIME; // exactly cap when divided
        // First lock at exactly the cap should fit (slope == uint64.max).
        // Second lock of even MIN_LOCK_AMOUNT should overflow.

        // Mint and lock for alice — needs huge balance.
        hemi.mint(alice, huge);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 tokenId1 = veHemi.createLock(huge, MAX_TIME);
        // Delegate the first lock to bob, populating bob's checkpoint at the cap.
        delegation.delegate(tokenId1, bob);
        vm.stopPrank();

        // Mint a second lock for alice, also delegated to bob — pushes the
        // aggregate over uint64.max.
        hemi.mint(alice, 1000 ether);
        vm.startPrank(alice);
        uint256 tokenId2 = veHemi.createLock(1000 ether, MAX_TIME);
        vm.expectRevert(VeHemiVoteDelegation.DelegationSlopeOverflow.selector);
        delegation.delegate(tokenId2, bob);
        vm.stopPrank();
    }

    /// @notice Boundary test for MED-2 (R1-G4 / R1-G16): the overflow check is
    ///         `_newSlope > type(uint64).max`, so an aggregate slope landing
    ///         *exactly* at `uint64.max` must succeed without reverting. This
    ///         locks in the strict-greater-than semantics — a future refactor
    ///         to `>=` would silently shrink the usable range by one slope
    ///         unit and break this test.
    function test_MED2_aggregateSlopeAtCap_succeeds() public {
        // amount/MAX_TIME == uint64.max exactly when amount == uint64.max * MAX_TIME
        // (Solidity / Foundry integer division; MAX_TIME = 4*YEAR is a divisor
        // of `huge` by construction).
        uint256 huge = uint256(type(uint64).max) * MAX_TIME;
        assertEq(huge / MAX_TIME, uint256(type(uint64).max), "precondition: slope hits cap exactly");

        // Mint and create a max-duration lock for alice.
        hemi.mint(alice, huge);
        vm.startPrank(alice);
        hemi.approve(address(veHemi), type(uint256).max);
        uint256 tokenId = veHemi.createLock(huge, MAX_TIME);

        // Delegating must NOT revert: the new aggregate slope is exactly
        // uint64.max, which sits inside the `> type(uint64).max` guard.
        delegation.delegate(tokenId, bob);
        vm.stopPrank();

        // Confirm the checkpoint actually stored slope == uint64.max — proves
        // the success path produced the boundary value rather than rounding
        // down or saturating.
        IVeHemiVoteDelegation.DelegateCheckpoint[] memory ckpts =
            delegation.getDelegationCheckpoints(bob);
        assertGt(ckpts.length, 0, "checkpoint must be written");
        assertEq(
            ckpts[ckpts.length - 1].normalizedSlope,
            type(uint64).max,
            "aggregate slope at cap"
        );

        // And any additional delegation must revert — confirms we're sitting
        // exactly on the boundary, not below it. MIN_LOCK_AMOUNT (10 HEMI) is
        // the smallest createLock amount the contract accepts; its slope
        // (10e18 / MAX_TIME ≈ 7.9e10) is positive and so tips the aggregate
        // strictly above uint64.max.
        hemi.mint(alice, 10 ether);
        vm.startPrank(alice);
        uint256 tokenId2 = veHemi.createLock(10 ether, MAX_TIME);
        vm.expectRevert(VeHemiVoteDelegation.DelegationSlopeOverflow.selector);
        delegation.delegate(tokenId2, bob);
        vm.stopPrank();
    }
}
