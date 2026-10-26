// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// The exhaustive interaction matrix.
///
/// Every cell is (entry point x position kind x phase x delegation shape):
/// build the subject position of that kind in that delegation shape, warp to
/// the phase, fire the entry point, then read every instant of interest in the
/// next two hours live, and replay the same instants through `getPastVotes`
/// at four later horizons (+1 s, +1 h, +30 d, +400 d).
///
/// The oracle reads no field the delegation bookkeeping writes:
///   VSUM(t) = sum of `getVotes(d)` over the watch set (every address that
///             could legitimately hold the subject's weight: owner, old and
///             new delegatee, companions' delegatee) — the DELEGATION contract;
///   ESUM(t) = sum of `balanceOfNFTAt(id, t)` over every position minted in
///             the cell — the ESCROW contract.
/// Neither side is recomputed from the weight formula, so a shared bug would
/// have to exist in both contracts independently.
///
/// Laws asserted on every cell:
///   LAW1  VSUM(t) > 0 whenever ESUM(t) > 0, at every instant after the firing
///         block (no zero-vote second);
///   LAW2  the same for the sealed `getPastVotes` replay at +400 d;
///   LAW3  `getPastVotes(t)` at every horizon equals the live reading at `t`
///         (history is never restated);
///   LAW4  VSUM(t) <= ESUM(t) at every instant after the firing block (no
///         over-count; any phantom is confined to the firing block itself).
/// The firing block T is excluded from LAW1/LAW4 on purpose: `_delegate`
/// dates both legs at `block.timestamp + 1` (the same-block flash-delegation
/// defence), so at T the escrow has moved and the votes have not.
///
/// Bodies: one per (entry point, kind) pair, covering its 10 phases x 4
/// shapes = 40 cells, so that every body fits the 2^30 per-test gas limit of
/// the default and ci profiles (`retireStale` on a flat kind is split into
/// three phase strips: its cells sit 61 six-day buckets past construction and
/// cost ~45M gas each). Every body requires the entry point to succeed in
/// each of its cells, so a call that starts reverting cannot hollow the
/// matrix out. Pairs where the entry point reverts in every cell have no
/// body (34 of 102: disable/refresh/retireStale on an unarmed position,
/// enable on an armed or expired one, withdraw before expiry, forfeit of a
/// non-forfeitable position, transfer of a non-transferable one, any
/// increase/re-delegation of an expired one). `delegate(id, address(0))` is
/// refused at the public surface and has no row: `_delegate(.., address(0))`
/// is reached through the `withdraw` and `forfeit` rows.
contract InteractionMatrixTest is LockedCurveTestBase {
    // ---- entry points ------------------------------------------------
    uint256 constant EP_INCREASE_AMOUNT      = 0;
    uint256 constant EP_INCREASE_UNLOCK_TIME = 1;
    uint256 constant EP_ENABLE               = 2;
    uint256 constant EP_DISABLE              = 3;
    uint256 constant EP_RETIRE_STALE         = 4;
    uint256 constant EP_REFRESH              = 5;
    uint256 constant EP_REDELEGATE_TO_SAME   = 6;
    uint256 constant EP_DELEGATE_TO_NEW      = 7;
    uint256 constant EP_DELEGATE_BY_SIG      = 8;
    uint256 constant EP_DELEGATE_ALL_FOR     = 9;
    uint256 constant EP_TRANSFER_FROM        = 10;
    uint256 constant EP_SAFE_TRANSFER_FROM   = 11;
    uint256 constant EP_CREATE_LOCK          = 12;
    uint256 constant EP_CREATE_LOCK_FOR      = 13;
    uint256 constant EP_WITHDRAW             = 14;
    uint256 constant EP_FORFEIT              = 15;
    uint256 constant EP_NOOP                 = 16;   // no trigger: the resting control

    // ---- position kinds ----------------------------------------------
    uint256 constant KIND_DECAYING                     = 0;
    uint256 constant KIND_FLAT                         = 1;
    uint256 constant KIND_FORFEITABLE                  = 2;
    uint256 constant KIND_NON_TRANSFERABLE             = 3;
    uint256 constant KIND_EXPIRED                      = 4;
    uint256 constant KIND_FLAT_PAST_TRANSFERABLE_AFTER = 5;

    // ---- delegation shapes -------------------------------------------
    uint256 constant SHAPE_SELF   = 0;  // mint default
    uint256 constant SHAPE_OTHER  = 1;
    uint256 constant SHAPE_SHARED = 2;  // two delegators, one delegatee
    uint256 constant SHAPE_MIXED  = 3;  // delegatee holds flat AND decaying
    uint256 constant SHAPE_COUNT = 4;

    uint256 constant PHASE_COUNT = 10;  // rows of the phase table
    uint256 constant HOUR = 1 hours;

    // ---- actors -------------------------------------------------------
    uint256 constant OWNER_PK = 0xA11CE;
    address OWNER;              // subject position owner (signer, for BySig)
    address constant DELEGATEE     = address(0xD0D0);   // primary delegatee
    address constant MOVE_TARGET   = address(0xD1D1);   // target of a delegatee move or transfer
    address constant COMPANION     = address(0xC0C0);   // companion owner
    address constant FORFEIT_ADMIN = address(0xFADA);

    // ---- per-cell state ----------------------------------------------
    uint256[] ids;        // every position minted in this cell
    address[] watch;      // every delegatee that could hold weight
    uint256 subject;      // the position the entry point is fired at
    uint256 fireT;        // the instant the entry point was fired

    struct CellResult {
        uint256 zeroAfter;        // LAW1: VSUM == 0 while ESUM > 0, t > T
        uint256 sealedZeroAfter;  // LAW2: sealed getPastVotes == 0 while ESUM > 0, t > T
        uint256 restatedReadings; // LAW3: replay != live reading
        uint256 overAfter;        // LAW4: VSUM > ESUM, t > T
    }

    function setUp() public override {
        super.setUp();
        OWNER = vm.addr(OWNER_PK);
        veHemi.updateForfeitAdmin(FORFEIT_ADMIN);
        // `delegateAllFor` demands a trusted adapter with code; this test
        // contract has code and `admin == address(this)` owns VeHemi.
        delegation.setTrustedAdapter(address(this));
        runSeedingFlow();
        hemi.mint(address(this), 10_000_000 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        address[8] memory actors = [OWNER, DELEGATEE, MOVE_TARGET, COMPANION, FORFEIT_ADMIN, alice, bob, charlie];
        for (uint256 i; i < actors.length; ++i) {
            hemi.mint(actors[i], 100_000 ether);
            vm.prank(actors[i]); hemi.approve(address(veHemi), type(uint256).max);
        }
    }

    // ===================================================================
    //  PHASES
    //
    //  Both grids are anchored at unix 0: the hourly checkpoint grid and the
    //  SIX_DAYS unlock grid. SIX_DAYS mod 3600 == 360, so an instant with
    //  six-day residue s has hourly residue in { (s + 360k) mod 3600 }: the
    //  pair (h, s) is reachable iff h ≡ s (mod 360). Every row of the table
    //  satisfies that; `_phaseT` finds the first such instant >= minT.
    // ===================================================================
    function _phaseT(uint256 minT, uint256 h, uint256 s) internal pure returns (uint256) {
        uint256 t = (minT / SIX_DAYS) * SIX_DAYS + s;
        while (t < minT) t += SIX_DAYS;
        for (uint256 i; i < 12; ++i) {
            if (t % HOUR == h) return t;
            t += SIX_DAYS;
        }
        return 0;
    }

    /// (hourly residue, six-day residue)
    function _phase(uint256 p) internal pure returns (uint256 h, uint256 s) {
        if (p == 0) return (0, 0);                    // both at a boundary
        if (p == 1) return (1, 1);                    // both just past
        if (p == 2) return (3599, SIX_DAYS - 1);      // both at the last second
        if (p == 3) return (1800, 0);                 // mid-hour, six-day edge
        if (p == 4) return (3598, SIX_DAYS - 2);
        if (p == 5) return (180,  SIX_DAYS / 2);
        if (p == 6) return (1980, SIX_DAYS / 2);      // late in the hour
        if (p == 7) return (1800, 3600);              // quiet control
        if (p == 8) return (1, 525241);               // h=1, far from a six-day edge
        if (p == 9) return (3599, 525239);            // h=3599, far from a six-day edge
        revert("no such phase");
    }

    // ===================================================================
    //  POSITIONS AND SHAPES
    // ===================================================================
    function _mkFor(address owner_, uint256 amt, uint256 dur, bool transferable, bool forfeitable)
        internal returns (uint256 id)
    {
        if (transferable) { vm.prank(owner_); id = veHemi.createLock(amt, dur); }
        else { id = veHemi.createLockFor(amt, dur, owner_, false, forfeitable); }
    }

    /// Build the SUBJECT position of the requested kind, owned by OWNER.
    function _buildSubject(uint256 kind) internal returns (uint256 id) {
        if (kind == KIND_DECAYING)              { id = _mkFor(OWNER, 500 ether, 40 * SIX_DAYS, true,  false); }
        else if (kind == KIND_FLAT)             {
            id = _mkFor(OWNER, 500 ether, 40 * SIX_DAYS, true, false);
            vm.prank(OWNER); veHemi.enableAutoRelock(id);
        }
        else if (kind == KIND_FORFEITABLE)      { id = _mkFor(OWNER, 500 ether, 40 * SIX_DAYS, false, true); }
        else if (kind == KIND_NON_TRANSFERABLE) { id = _mkFor(OWNER, 500 ether, 40 * SIX_DAYS, false, false); }
        else if (kind == KIND_EXPIRED)          { id = _mkFor(OWNER, 500 ether, 2 * SIX_DAYS, true, false); }
        else if (kind == KIND_FLAT_PAST_TRANSFERABLE_AFTER) {
            // non-transferable => transferableAfter == unlockTime; go flat,
            // then (in `_cell`) let the ORIGINAL transferableAfter pass.
            id = _mkFor(OWNER, 500 ether, 2 * SIX_DAYS, false, false);
            vm.prank(OWNER); veHemi.enableAutoRelock(id);
        }
        else revert("no such kind");
    }

    /// Point the subject at the shape's delegatee and mint companions.
    function _applyShape(uint256 shape) internal {
        watch.push(OWNER); watch.push(DELEGATEE); watch.push(MOVE_TARGET);
        if (shape == SHAPE_SELF) return;   // the untouched mint default
        if (shape == SHAPE_OTHER) { vm.prank(OWNER); delegation.delegate(subject, DELEGATEE); return; }
        if (shape == SHAPE_SHARED) {
            vm.prank(OWNER); delegation.delegate(subject, DELEGATEE);
            uint256 companionId = _mkFor(COMPANION, 300 ether, 40 * SIX_DAYS, true, false);
            ids.push(companionId);
            vm.prank(COMPANION); delegation.delegate(companionId, DELEGATEE);
            return;
        }
        // SHAPE_MIXED: DELEGATEE holds one FLAT and one DECAYING record besides the
        // subject, so the subject's move has to leave both intact.
        vm.prank(OWNER); delegation.delegate(subject, DELEGATEE);
        uint256 flatCompanionId = _mkFor(COMPANION, 300 ether, 40 * SIX_DAYS, true, false);
        vm.prank(COMPANION); veHemi.enableAutoRelock(flatCompanionId);
        vm.prank(COMPANION); delegation.delegate(flatCompanionId, DELEGATEE);
        uint256 decayingCompanionId = _mkFor(charlie, 200 ether, 40 * SIX_DAYS, true, false);
        vm.prank(charlie); delegation.delegate(decayingCompanionId, DELEGATEE);
        ids.push(flatCompanionId); ids.push(decayingCompanionId); watch.push(COMPANION); watch.push(charlie);
    }

    // ===================================================================
    //  ENTRY POINTS. Return false when the call reverts; `_laws` fails the
    //  body on that, so a cell can never pass by not running.
    // ===================================================================
    function _fire(uint256 ep) internal returns (bool ok) {
        uint256 id = subject;
        if (ep == EP_INCREASE_AMOUNT) {
            hemi.mint(OWNER, 1);
            vm.prank(OWNER); try veHemi.increaseAmount(id, 1) { return true; } catch { return false; }
        }
        if (ep == EP_INCREASE_UNLOCK_TIME) {
            vm.prank(OWNER); try veHemi.increaseUnlockTime(id, 60 * SIX_DAYS) { return true; } catch { return false; }
        }
        if (ep == EP_ENABLE) {
            vm.prank(OWNER); try veHemi.enableAutoRelock(id) { return true; } catch { return false; }
        }
        if (ep == EP_DISABLE) {
            vm.prank(OWNER); try veHemi.disableAutoRelock(id) { return true; } catch { return false; }
        }
        if (ep == EP_RETIRE_STALE) {
            vm.prank(charlie); try veHemi.retireStaleAutoRelock(id) { return true; } catch { return false; }
        }
        if (ep == EP_REFRESH) {
            // owner-only
            vm.prank(OWNER); try veHemi.refreshAutoRelock(id) { return true; } catch { return false; }
        }
        if (ep == EP_REDELEGATE_TO_SAME) {
            address cur = delegation.delegation(id).delegatee;
            if (cur == address(0)) return false;
            vm.prank(OWNER); try delegation.delegate(id, cur) { return true; } catch { return false; }
        }
        if (ep == EP_DELEGATE_TO_NEW) {
            vm.prank(OWNER); try delegation.delegate(id, MOVE_TARGET) { return true; } catch { return false; }
        }
        if (ep == EP_DELEGATE_BY_SIG) {
            uint256 nonce = delegation.nonces(OWNER);
            uint256 expiry = block.timestamp + 1 days;
            bytes32 digest = _sigDigest(id, MOVE_TARGET, nonce, expiry);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);
            try delegation.delegateBySig(id, MOVE_TARGET, nonce, expiry, v, r, s) { return true; } catch { return false; }
        }
        if (ep == EP_DELEGATE_ALL_FOR) {
            try delegation.delegateAllFor(OWNER, MOVE_TARGET) { return true; } catch { return false; }
        }
        if (ep == EP_TRANSFER_FROM) {
            vm.prank(OWNER); try veHemi.transferFrom(OWNER, MOVE_TARGET, id) { return true; } catch { return false; }
        }
        if (ep == EP_SAFE_TRANSFER_FROM) {
            vm.prank(OWNER); try veHemi.safeTransferFrom(OWNER, MOVE_TARGET, id) { return true; } catch { return false; }
        }
        if (ep == EP_CREATE_LOCK) {
            vm.prank(OWNER); try veHemi.createLock(200 ether, 40 * SIX_DAYS) returns (uint256 nid) { ids.push(nid); return true; } catch { return false; }
        }
        if (ep == EP_CREATE_LOCK_FOR) {
            try veHemi.createLockFor(200 ether, 40 * SIX_DAYS, OWNER, false, false) returns (uint256 nid) { ids.push(nid); return true; } catch { return false; }
        }
        if (ep == EP_WITHDRAW) {
            vm.prank(OWNER); try veHemi.withdraw(id) { return true; } catch { return false; }
        }
        if (ep == EP_FORFEIT) {
            vm.prank(FORFEIT_ADMIN); try veHemi.forfeit(id) { return true; } catch { return false; }
        }
        if (ep == EP_NOOP) return true;
        revert("no such entry point");
    }

    function _sigDigest(uint256 id, address delegatee, uint256 nonce, uint256 expiry)
        internal view returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("veHEMIDelegation")), keccak256(bytes("1.0.0")),
            block.chainid, address(delegation)));
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Delegation(uint256 delegator,address delegatee,uint256 nonce,uint256 expiry)"),
            id, delegatee, nonce, expiry));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // ===================================================================
    //  SAMPLING
    // ===================================================================

    /// The instants read for a fire at T, sorted: T-1 and T themselves (the
    /// escrow dates a retirement at `block.timestamp`, the delegation at
    /// `block.timestamp + 1`), T+1..T+3, the hour at a 60 s stride, T+2h,
    /// both sides of the next two hourly boundaries, and both sides of the
    /// next six-day boundary when it falls inside the window.
    function _samples(uint256 T) internal pure returns (uint256[] memory s) {
        s = new uint256[](80);
        uint256 n;
        uint256 B  = (T / HOUR) * HOUR + HOUR;             // next hourly boundary
        uint256 B2 = B + HOUR;
        uint256 S  = (T / SIX_DAYS) * SIX_DAYS + SIX_DAYS; // next six-day boundary
        s[n++] = T - 1; s[n++] = T;
        s[n++] = T + 1; s[n++] = T + 2; s[n++] = T + 3;
        for (uint256 k = 60; k <= 3600; k += 60) s[n++] = T + k;
        s[n++] = T + 7200;
        s[n++] = B - 2; s[n++] = B - 1; s[n++] = B; s[n++] = B + 1; s[n++] = B + 2;
        s[n++] = B2 - 1; s[n++] = B2; s[n++] = B2 + 1;
        if (S < T + 2 * HOUR) { s[n++] = S - 1; s[n++] = S; s[n++] = S + 1; }
        assembly { mstore(s, n) }
        for (uint256 i = 1; i < n; ++i) {
            uint256 v = s[i]; uint256 j = i;
            while (j > 0 && s[j - 1] > v) { s[j] = s[j - 1]; --j; }
            s[j] = v;
        }
    }

    function _vsum() internal view returns (uint256 v) {
        for (uint256 i; i < watch.length; ++i) v += delegation.getVotes(watch[i]);
    }
    function _vsumPast(uint256 t) internal view returns (uint256 v) {
        for (uint256 i; i < watch.length; ++i) v += delegation.getPastVotes(watch[i], t);
    }
    /// A burned id reverts inside `balanceOfNFTAt`; a burned position holds no
    /// escrow, so a revert contributes 0, without the oracle having to know
    /// which entry point burned the token.
    function _esum(uint256 t) internal view returns (uint256 e) {
        for (uint256 i; i < ids.length; ++i) {
            try veHemi.balanceOfNFTAt(ids[i], t) returns (uint256 b) { e += b; } catch {}
        }
    }

    /// Read the instants live, then replay them through `getPastVotes` at
    /// four horizons. LAW3 compares the replay with the live reading, not
    /// with a recomputed expectation.
    function _sweep(uint256[] memory ts) internal returns (CellResult memory r) {
        uint256 n = ts.length;
        uint256[] memory live = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            vm.warp(ts[i]);
            uint256 v = _vsum();
            live[i] = v;
            if (ts[i] > fireT) {
                uint256 e = _esum(ts[i]);
                if (v == 0 && e > 0) ++r.zeroAfter;
                if (v > e) ++r.overAfter;
            }
        }
        uint256 last = ts[n - 1];
        for (uint256 hzn; hzn < 4; ++hzn) {
            vm.warp(last + (hzn == 0 ? 1 : hzn == 1 ? 1 hours : hzn == 2 ? 30 days : 400 days));
            for (uint256 i; i < n; ++i) {
                uint256 pv = _vsumPast(ts[i]);
                if (pv != live[i]) ++r.restatedReadings;
                if (hzn == 3 && pv == 0 && ts[i] > fireT && _esum(ts[i]) > 0) ++r.sealedZeroAfter;
            }
        }
    }

    // ===================================================================
    //  THE CELL
    // ===================================================================
    function _cell(uint256 ep, uint256 kind, uint256 p, uint256 shape)
        internal returns (bool reached, CellResult memory r)
    {
        delete ids; delete watch;
        (uint256 h, uint256 s) = _phase(p);

        // Mint at a quiet instant, so construction cannot itself land on the
        // phase under test; then warp to the phase and fire.
        uint256 t0 = ((block.timestamp / SIX_DAYS) + 2) * SIX_DAYS + 1800;
        vm.warp(t0);
        subject = _buildSubject(kind);
        ids.push(subject);
        _applyShape(shape);

        uint256 minT = t0 + 3 * HOUR;
        if (ep == EP_RETIRE_STALE) {
            minT = t0 + 61 * SIX_DAYS;          // STALE_FLAT_BUCKETS(60) of owner silence
        } else if (kind == KIND_EXPIRED || kind == KIND_FLAT_PAST_TRANSFERABLE_AFTER) {
            minT = t0 + 3 * SIX_DAYS;           // past the 2*SIX_DAYS lock / original transferableAfter
        }
        uint256 T = _phaseT(minT, h, s);
        require(T != 0, "phase row violates h == s (mod 360)");
        vm.warp(T);

        fireT = T;
        if (!_fire(ep)) return (false, r);
        reached = true;
        r = _sweep(_samples(T));
    }

    function _coord(uint256 ep, uint256 kind, uint256 p, uint256 shape) internal pure returns (string memory) {
        return string.concat(" at cell ep=", vm.toString(ep), " kind=", vm.toString(kind),
                             " phase=", vm.toString(p), " shape=", vm.toString(shape));
    }

    function _check(uint256 ep, uint256 kind, uint256 p, uint256 shape, CellResult memory r) internal pure {
        if (r.zeroAfter != 0) {
            revert(string.concat("LAW1 zero votes after the firing block", _coord(ep, kind, p, shape)));
        }
        if (r.sealedZeroAfter != 0) {
            revert(string.concat(
                "LAW2 zero sealed into getPastVotes after the firing block", _coord(ep, kind, p, shape)
            ));
        }
        if (r.restatedReadings != 0) {
            revert(string.concat("LAW3 getPastVotes changed between horizons", _coord(ep, kind, p, shape)));
        }
        if (r.overAfter != 0) {
            revert(string.concat("LAW4 over-count after the firing block", _coord(ep, kind, p, shape)));
        }
    }

    /// Run the cells of one (entry point, kind) pair for phases [pLo, pHi)
    /// and every shape; each must be reached, and must satisfy every law.
    function _laws(uint256 ep, uint256 kind, uint256 pLo, uint256 pHi) internal {
        uint256 snap = vm.snapshotState();
        for (uint256 p = pLo; p < pHi; ++p) {
            for (uint256 shape; shape < SHAPE_COUNT; ++shape) {
                vm.revertToState(snap);
                snap = vm.snapshotState();
                (bool reached, CellResult memory r) = _cell(ep, kind, p, shape);
                if (!reached) revert(string.concat("the entry point reverted", _coord(ep, kind, p, shape)));
                _check(ep, kind, p, shape, r);
            }
        }
    }
    function _laws(uint256 ep, uint256 kind) internal { _laws(ep, kind, 0, PHASE_COUNT); }

    // ===================================================================
    //  THE BODIES
    // ===================================================================
    function test_increaseAmount_decaying() public { _laws(EP_INCREASE_AMOUNT, KIND_DECAYING); }
    function test_increaseAmount_flat() public { _laws(EP_INCREASE_AMOUNT, KIND_FLAT); }
    function test_increaseAmount_forfeitable() public { _laws(EP_INCREASE_AMOUNT, KIND_FORFEITABLE); }
    function test_increaseAmount_nonTransferable() public { _laws(EP_INCREASE_AMOUNT, KIND_NON_TRANSFERABLE); }
    function test_increaseAmount_flatPastTransferableAfter() public { _laws(EP_INCREASE_AMOUNT, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_increaseUnlockTime_decaying() public { _laws(EP_INCREASE_UNLOCK_TIME, KIND_DECAYING); }
    function test_increaseUnlockTime_flat() public { _laws(EP_INCREASE_UNLOCK_TIME, KIND_FLAT); }
    function test_increaseUnlockTime_forfeitable() public { _laws(EP_INCREASE_UNLOCK_TIME, KIND_FORFEITABLE); }
    function test_increaseUnlockTime_nonTransferable() public { _laws(EP_INCREASE_UNLOCK_TIME, KIND_NON_TRANSFERABLE); }
    function test_increaseUnlockTime_flatPastTransferableAfter() public { _laws(EP_INCREASE_UNLOCK_TIME, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_enable_decaying() public { _laws(EP_ENABLE, KIND_DECAYING); }
    function test_enable_forfeitable() public { _laws(EP_ENABLE, KIND_FORFEITABLE); }
    function test_enable_nonTransferable() public { _laws(EP_ENABLE, KIND_NON_TRANSFERABLE); }

    function test_disable_flat() public { _laws(EP_DISABLE, KIND_FLAT); }
    function test_disable_flatPastTransferableAfter() public { _laws(EP_DISABLE, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_retireStale_flat_phases0to3() public { _laws(EP_RETIRE_STALE, KIND_FLAT, 0, 4); }
    function test_retireStale_flat_phases4to6() public { _laws(EP_RETIRE_STALE, KIND_FLAT, 4, 7); }
    function test_retireStale_flat_phases7to9() public { _laws(EP_RETIRE_STALE, KIND_FLAT, 7, 10); }
    function test_retireStale_flatPastTransferableAfter_phases0to3() public { _laws(EP_RETIRE_STALE, KIND_FLAT_PAST_TRANSFERABLE_AFTER, 0, 4); }
    function test_retireStale_flatPastTransferableAfter_phases4to6() public { _laws(EP_RETIRE_STALE, KIND_FLAT_PAST_TRANSFERABLE_AFTER, 4, 7); }
    function test_retireStale_flatPastTransferableAfter_phases7to9() public { _laws(EP_RETIRE_STALE, KIND_FLAT_PAST_TRANSFERABLE_AFTER, 7, 10); }

    function test_refresh_flat() public { _laws(EP_REFRESH, KIND_FLAT); }
    function test_refresh_flatPastTransferableAfter() public { _laws(EP_REFRESH, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_redelegateToSameDelegatee_decaying() public { _laws(EP_REDELEGATE_TO_SAME, KIND_DECAYING); }
    function test_redelegateToSameDelegatee_flat() public { _laws(EP_REDELEGATE_TO_SAME, KIND_FLAT); }
    function test_redelegateToSameDelegatee_forfeitable() public { _laws(EP_REDELEGATE_TO_SAME, KIND_FORFEITABLE); }
    function test_redelegateToSameDelegatee_nonTransferable() public { _laws(EP_REDELEGATE_TO_SAME, KIND_NON_TRANSFERABLE); }
    function test_redelegateToSameDelegatee_flatPastTransferableAfter() public { _laws(EP_REDELEGATE_TO_SAME, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_delegateToNewDelegatee_decaying() public { _laws(EP_DELEGATE_TO_NEW, KIND_DECAYING); }
    function test_delegateToNewDelegatee_flat() public { _laws(EP_DELEGATE_TO_NEW, KIND_FLAT); }
    function test_delegateToNewDelegatee_forfeitable() public { _laws(EP_DELEGATE_TO_NEW, KIND_FORFEITABLE); }
    function test_delegateToNewDelegatee_nonTransferable() public { _laws(EP_DELEGATE_TO_NEW, KIND_NON_TRANSFERABLE); }
    function test_delegateToNewDelegatee_flatPastTransferableAfter() public { _laws(EP_DELEGATE_TO_NEW, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_delegateBySig_decaying() public { _laws(EP_DELEGATE_BY_SIG, KIND_DECAYING); }
    function test_delegateBySig_flat() public { _laws(EP_DELEGATE_BY_SIG, KIND_FLAT); }
    function test_delegateBySig_forfeitable() public { _laws(EP_DELEGATE_BY_SIG, KIND_FORFEITABLE); }
    function test_delegateBySig_nonTransferable() public { _laws(EP_DELEGATE_BY_SIG, KIND_NON_TRANSFERABLE); }
    function test_delegateBySig_flatPastTransferableAfter() public { _laws(EP_DELEGATE_BY_SIG, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_delegateAllFor_decaying() public { _laws(EP_DELEGATE_ALL_FOR, KIND_DECAYING); }
    function test_delegateAllFor_flat() public { _laws(EP_DELEGATE_ALL_FOR, KIND_FLAT); }
    function test_delegateAllFor_forfeitable() public { _laws(EP_DELEGATE_ALL_FOR, KIND_FORFEITABLE); }
    function test_delegateAllFor_nonTransferable() public { _laws(EP_DELEGATE_ALL_FOR, KIND_NON_TRANSFERABLE); }
    function test_delegateAllFor_expired() public { _laws(EP_DELEGATE_ALL_FOR, KIND_EXPIRED); }
    function test_delegateAllFor_flatPastTransferableAfter() public { _laws(EP_DELEGATE_ALL_FOR, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_transferFrom_decaying() public { _laws(EP_TRANSFER_FROM, KIND_DECAYING); }
    function test_transferFrom_flat() public { _laws(EP_TRANSFER_FROM, KIND_FLAT); }
    function test_transferFrom_expired() public { _laws(EP_TRANSFER_FROM, KIND_EXPIRED); }
    function test_transferFrom_flatPastTransferableAfter() public { _laws(EP_TRANSFER_FROM, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_safeTransferFrom_decaying() public { _laws(EP_SAFE_TRANSFER_FROM, KIND_DECAYING); }
    function test_safeTransferFrom_flat() public { _laws(EP_SAFE_TRANSFER_FROM, KIND_FLAT); }
    function test_safeTransferFrom_expired() public { _laws(EP_SAFE_TRANSFER_FROM, KIND_EXPIRED); }
    function test_safeTransferFrom_flatPastTransferableAfter() public { _laws(EP_SAFE_TRANSFER_FROM, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_createLock_decaying() public { _laws(EP_CREATE_LOCK, KIND_DECAYING); }
    function test_createLock_flat() public { _laws(EP_CREATE_LOCK, KIND_FLAT); }
    function test_createLock_forfeitable() public { _laws(EP_CREATE_LOCK, KIND_FORFEITABLE); }
    function test_createLock_nonTransferable() public { _laws(EP_CREATE_LOCK, KIND_NON_TRANSFERABLE); }
    function test_createLock_expired() public { _laws(EP_CREATE_LOCK, KIND_EXPIRED); }
    function test_createLock_flatPastTransferableAfter() public { _laws(EP_CREATE_LOCK, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_createLockFor_decaying() public { _laws(EP_CREATE_LOCK_FOR, KIND_DECAYING); }
    function test_createLockFor_flat() public { _laws(EP_CREATE_LOCK_FOR, KIND_FLAT); }
    function test_createLockFor_forfeitable() public { _laws(EP_CREATE_LOCK_FOR, KIND_FORFEITABLE); }
    function test_createLockFor_nonTransferable() public { _laws(EP_CREATE_LOCK_FOR, KIND_NON_TRANSFERABLE); }
    function test_createLockFor_expired() public { _laws(EP_CREATE_LOCK_FOR, KIND_EXPIRED); }
    function test_createLockFor_flatPastTransferableAfter() public { _laws(EP_CREATE_LOCK_FOR, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }

    function test_withdraw_expired() public { _laws(EP_WITHDRAW, KIND_EXPIRED); }

    function test_forfeit_forfeitable() public { _laws(EP_FORFEIT, KIND_FORFEITABLE); }

    function test_noop_decaying() public { _laws(EP_NOOP, KIND_DECAYING); }
    function test_noop_flat() public { _laws(EP_NOOP, KIND_FLAT); }
    function test_noop_forfeitable() public { _laws(EP_NOOP, KIND_FORFEITABLE); }
    function test_noop_nonTransferable() public { _laws(EP_NOOP, KIND_NON_TRANSFERABLE); }
    function test_noop_expired() public { _laws(EP_NOOP, KIND_EXPIRED); }
    function test_noop_flatPastTransferableAfter() public { _laws(EP_NOOP, KIND_FLAT_PAST_TRANSFERABLE_AFTER); }
}
