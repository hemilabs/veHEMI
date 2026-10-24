// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockUpgradeForkBase.sol";

interface IVoteDelegationOps {
    function delegateAllFor(address owner_, address delegatee_) external;
    function delegateBySig(uint256, address, uint256, uint256, uint8, bytes32, bytes32) external;
    function nonces(address) external view returns (uint256);
    function setAutoDelegate(address) external;
    function writeNewCheckpointForExpiredDelegations(address) external;
    function refreshVotingPower(address) external;
    function refreshVotingPowerBatch(address[] calldata) external;
    function getPastVotes(address, uint256) external view returns (uint256);
    function delegate(uint256, address) external;
}

interface IVeHemiOps {
    function createLock(uint256 amount, uint256 lockDuration) external returns (uint256);
    function increaseAmount(uint256 tokenId, uint256 amount) external;
    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external;
    function withdraw(uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function isTransferable(uint256 tokenId) external view returns (bool);
    function nextTokenId() external view returns (uint256);
}

/**
 * TWIN-UNIVERSE oracle for the upgrade-hour window. The same operation list
 * runs in two worlds from one forked state that already holds
 * deployed-implementation writes made earlier in the upgrade hour (moves, a
 * same-block burst):
 *   L: VeHemi upgraded, VVD LEFT ON THE DEPLOYED IMPLEMENTATION (the live writer);
 *   W: the shipped batch (VVD via upgradeAndCall(armLegacyDatingWindow())).
 * Every window write must leave the VVD in EXACTLY the raw state the live
 * writer leaves (checkpoint-array tails, expiration buckets, records), emit
 * the same DelegateVotesChanged stream, and serve the same getPastVotes on a
 * lattice spanning the hour and the next one (read after B + 1 h, through each
 * world's own reader). History at or before U (the window operations start at
 * U + 12) never moves.
 */
contract UpgradeWindowTwinForkTest is AutoRelockUpgradeForkBase {
    address constant ADAPTER = 0x3f41c138082b29fb1a6c91066e73480163f984e4;

    struct TW {
        uint256 h;
        uint256 U;
        uint256 B;
        uint256 K;
        uint256 eEnd;
        uint256 id1; address o1; address a1;
        uint256 id2; address o2; address a2;
        uint256 id4; address o4; address a4;
        uint256 id6; address o6; address a6;
        uint256 idK; address pK;
        uint256 idE; address pE;
        uint256 idA1; uint256 idA2; address pA; // amortiser: one expired + one live decaying lock
        uint256 idS; address pS; uint256 keyS;
        address pZ; address dZ;
        address f1; address f2; address g1; address g2; address g3; address buyer4;
        uint256[5] bId; address[5] bO; address[5] bA; address[5] bF;
        address gb4;
    }

    function _addr(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(s)))));
    }

    function _fund(address who, uint256 amt) internal {
        deal(HEMI_TOKEN, who, amt);
        vm.prank(who);
        IForkERC20(HEMI_TOKEN).approve(VEHEMI_PROXY, type(uint256).max);
    }

    function _lockUntil(address who, uint256 end_) internal returns (uint256 id) {
        _fund(who, 100e18);
        vm.prank(who);
        id = IVeHemiOps(VEHEMI_PROXY).createLock(100e18, end_ - block.timestamp + 1);
        assertEq(uint256(veHemi.getLockedBalance(id).end), end_, "lock end not on the grid point");
    }

    function _pickTransferable(uint256 from_) internal view returns (uint256 id, address owner, address a) {
        uint256 hi = vm.envOr("AUTORELOCK_FORK_SCAN_HI", uint256(29720));
        for (uint256 i = from_; i < hi; ++i) {
            (address d,,,,) = vvd.delegations(i);
            if (d == address(0)) continue;
            if (uint256(veHemi.getLockedBalance(i).end) < block.timestamp + 60 days) continue;
            if (!IVeHemiOps(VEHEMI_PROXY).isTransferable(i)) continue;
            if (veHemi.balanceOfNFT(i) < 1e18) continue;
            return (i, veHemi.ownerOf(i), d);
        }
        revert("no transferable position");
    }

    /// @dev Shared pre-state: locks at t0, then deployed-implementation
    ///      writes in the window hour h before U.
    function _setup() internal returns (TW memory t) {
        uint256 t0 = block.timestamp;
        uint256 n = (t0 + 2 * SIX_DAYS + HOUR) / SIX_DAYS + 1;
        t.eEnd = n * SIX_DAYS;
        n = (t.eEnd + 2 * HOUR) / SIX_DAYS + 1;
        while ((n * SIX_DAYS) % HOUR < 1800) ++n;
        t.K = n * SIX_DAYS;
        t.h = t.K - (t.K % HOUR);
        t.U = t.h + 1211;
        t.B = t.h + HOUR;
        t.pK = _addr("twin-pK");
        t.pE = _addr("twin-pE");
        t.pA = _addr("twin-pA");
        t.keyS = uint256(keccak256("twin-keyS"));
        t.pS = vm.addr(t.keyS);
        t.pZ = _addr("twin-pZ");
        t.dZ = _addr("twin-dZ");
        t.f1 = _addr("twin-f1"); t.f2 = _addr("twin-f2");
        t.g1 = _addr("twin-g1"); t.g2 = _addr("twin-g2"); t.g3 = _addr("twin-g3");
        t.buyer4 = _addr("twin-buyer4");
        t.gb4 = _addr("twin-gb4");
        // t0: deployed VeHemi + VVD.
        t.idE = _lockUntil(t.pE, t.eEnd);
        t.idK = _lockUntil(t.pK, t.K);
        t.idA1 = _lockUntil(t.pA, t.eEnd);
        t.idA2 = _lockUntil(t.pA, ((t0 + 300 days) / SIX_DAYS) * SIX_DAYS);
        t.idS = _lockUntil(t.pS, ((t0 + 200 days) / SIX_DAYS) * SIX_DAYS);
        _fund(t.pZ, 100e18);
        vm.prank(t.pZ);
        IVoteDelegationOps(VVD_PROXY).setAutoDelegate(t.dZ);

        // The window hour.
        _to(t.h + 611);
        (t.id1, t.o1, t.a1) = _pick();
        (t.id2, t.o2, t.a2) = _pickFrom(t.id1 + 1, 1e18);
        (t.id6, t.o6, t.a6) = _pickFrom(t.id2 + 1, 1e18);
        (t.id4, t.o4, t.a4) = _pickTransferable(t.id6 + 1);
        _fund(t.o6, 10e18);
        uint256 next = t.id4 + 1;
        for (uint256 i; i < 5; ++i) {
            (t.bId[i], t.bO[i], t.bA[i]) = _pickFrom(next, 1e18);
            next = t.bId[i] + 1;
            t.bF[i] = _addr(string.concat("twin-bF", vm.toString(i)));
        }
        vm.prank(t.o1);
        vvd.delegate(t.id1, t.f1); // live: in-hour booking at fresh f1 (len 1, pending only)
        vm.prank(t.o2);
        vvd.delegate(t.id2, t.f2); // live: in-hour retirement from a2
        _to(t.U - 12);
        for (uint256 i; i < 5; ++i) {
            vm.prank(t.bO[i]);
            vvd.delegate(t.bId[i], t.bF[i]); // live burst, one block before U
        }
        _to(t.U);
    }

    function _ds(TW memory t) internal pure returns (address[] memory ds) {
        ds = new address[](27);
        address[21] memory x = [t.a1, t.f1, t.g1, t.a2, t.f2, t.g2, t.g3, t.pS, t.a4, t.buyer4, t.a6, t.pK, t.pE, t.dZ, t.pZ, t.gb4, t.o4, t.bA[0], t.bA[1], t.bA[2], t.bA[3]];
        for (uint256 i; i < 21; ++i) ds[i] = x[i];
        ds[21] = t.bA[4];
        for (uint256 i; i < 4; ++i) ds[22 + i] = t.bF[i];
        ds[26] = t.pA;
    }

    function _ids(TW memory t) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](13);
        uint256[8] memory x = [t.id1, t.id2, t.id4, t.id6, t.idK, t.idE, t.idS, t.idA2];
        for (uint256 i; i < 8; ++i) ids[i] = x[i];
        for (uint256 i; i < 5; ++i) ids[8 + i] = t.bId[i];
    }

    function _keys(TW memory t, uint256 zId) internal view returns (uint256[] memory keys) {
        uint256[] memory ids = _ids(t);
        keys = new uint256[](ids.length + 3);
        for (uint256 i; i < ids.length; ++i) keys[i] = uint256(veHemi.getLockedBalance(ids[i]).end);
        keys[ids.length] = t.K;
        keys[ids.length + 1] = t.eEnd;
        keys[ids.length + 2] = zId == 0 ? 0 : uint256(veHemi.getLockedBalance(zId).end);
    }

    /// @dev The window operation list (U+12 .. U+84; all before K).
    function _ops(TW memory t) internal returns (uint256 zId) {
        _to(t.U + 12);
        vm.prank(t.o1);
        vvd.delegate(t.id1, t.g1); // retire a legacy in-hour booking
        vm.prank(t.o2);
        vvd.delegate(t.id2, t.a2); // re-add a legacy in-hour retirement
        _to(t.U + 24);
        {
            uint256 nonce = IVoteDelegationOps(VVD_PROXY).nonces(t.pS);
            uint256 expiry = block.timestamp + 1 days;
            bytes32 ds_ = keccak256(abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("veHEMIDelegation")), keccak256(bytes("1.0.0")), block.chainid, VVD_PROXY));
            bytes32 sh = keccak256(abi.encode(
                keccak256("Delegation(uint256 delegator,address delegatee,uint256 nonce,uint256 expiry)"),
                t.idS, t.g2, nonce, expiry));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(t.keyS, keccak256(abi.encodePacked("\x19\x01", ds_, sh)));
            IVoteDelegationOps(VVD_PROXY).delegateBySig(t.idS, t.g2, nonce, expiry, v, r, s);
        }
        vm.prank(ADAPTER);
        IVoteDelegationOps(VVD_PROXY).delegateAllFor(t.pS, t.g3); // window -> window move of idS
        _to(t.U + 36);
        vm.prank(t.o4);
        IVeHemiOps(VEHEMI_PROXY).transferFrom(t.o4, t.buyer4, t.id4);
        vm.prank(t.pZ);
        zId = IVeHemiOps(VEHEMI_PROXY).createLock(100e18, 3 * SIX_DAYS); // auto-delegates to dZ
        _to(t.U + 48);
        vm.prank(t.o6);
        IVeHemiOps(VEHEMI_PROXY).increaseAmount(t.id6, 10e18);
        vm.prank(t.pK);
        IVeHemiOps(VEHEMI_PROXY).increaseUnlockTime(t.idK, 4 * SIX_DAYS); // retire a record with end K in (now+1, B]
        _to(t.U + 60);
        try IVoteDelegationOps(VVD_PROXY).writeNewCheckpointForExpiredDelegations(t.pE) {} catch {}
        // amortiser on a delegatee with a due bucket AND live decaying weight:
        // its event values differ between `block.timestamp + 1` and B.
        IVoteDelegationOps(VVD_PROXY).writeNewCheckpointForExpiredDelegations(t.pA);
        vm.prank(t.pE);
        IVeHemiOps(VEHEMI_PROXY).withdraw(t.idE); // retire an EXPIRED record (burn)
        _to(t.U + 72);
        for (uint256 i; i < 3; ++i) {
            vm.prank(t.bO[i]);
            vvd.delegate(t.bId[i], t.bA[i]); // undo the live burst
        }
        vm.prank(t.bO[3]);
        vvd.delegate(t.bId[3], t.gb4);
        _to(t.U + 84);
        IVoteDelegationOps(VVD_PROXY).refreshVotingPower(t.a1);
        address[] memory batch = new address[](3);
        batch[0] = t.g1; batch[1] = t.a2; batch[2] = t.f1;
        IVoteDelegationOps(VVD_PROXY).refreshVotingPowerBatch(batch);
    }

    function _lattice(TW memory t) internal pure returns (uint256[12] memory l) {
        l = [t.h + 1, t.h + 612, t.U - 1, t.U, t.U + 13, t.U + 49, t.U + 85, t.B - 1, t.B, t.B + 1, t.B + 1800, t.B + HOUR];
    }

    struct Seen {
        bytes32[] raw;
        bytes32[] ev;
        uint256[] past;
        uint256[] hist;
    }

    function _histPoints(TW memory t) internal pure returns (uint256[4] memory p) {
        p = [t.h + 1, t.h + 612, t.U - 12, t.U];
    }

    function _readHist(TW memory t, address[] memory ds) internal view returns (uint256[] memory out) {
        uint256[4] memory p = _histPoints(t);
        out = new uint256[](ds.length * 4);
        for (uint256 i; i < ds.length; ++i) {
            for (uint256 j; j < 4; ++j) out[i * 4 + j] = IVoteDelegationOps(VVD_PROXY).getPastVotes(ds[i], p[j]);
        }
    }

    function _world(TW memory t, bool window_) internal returns (Seen memory s) {
        if (window_) _upgradeBoth();
        else _upgradeVeHemiOnly();
        address[] memory ds = _ds(t);
        uint256[] memory histBefore = _readHist(t, ds);
        vm.recordLogs();
        uint256 zId = _ops(t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        s.ev = _dvc(logs);
        // Non-vacuity: the ops really ran, and nothing was swallowed.
        assertGe(s.ev.length, 25, "twin: too few DelegateVotesChanged events -- ops did not run");
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("DelegationUpdateFailed(uint256)")), 0, "twin: DUF");
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("DelegationUpdateFailedReason(uint256,bytes4)")), 0, "twin: DUF reason");
        assertEq(_countTopic(logs, VEHEMI_PROXY, keccak256("AutoRelockRetirementUnverified(uint256)")), 0, "twin: Unverified");
        _postconditions(t, zId);
        if (window_) {
            assertEq(uint256(vvd.delegationBookedAt(t.id1)), t.B, "W: window stamp != B");
            assertEq(uint256(vvd.delegationBookedAt(zId)), t.B, "W: window stamp (createLock) != B");
        }
        _toAfterB(t.B + HOUR);
        s.hist = _readHist(t, ds);
        for (uint256 i; i < histBefore.length; ++i) {
            assertEq(s.hist[i], histBefore[i], "history at or before U restated");
        }
        s.raw = _observeTails(ds, _ids(t), _keys(t, zId));
        uint256[12] memory l = _lattice(t);
        s.past = new uint256[](ds.length * 12);
        for (uint256 i; i < ds.length; ++i) {
            for (uint256 j; j < 12; ++j) s.past[i * 12 + j] = IVoteDelegationOps(VVD_PROXY).getPastVotes(ds[i], l[j]);
        }
        // truth after B (live semantics): the window moves have landed.
        (address d1,,,,) = vvd.delegations(t.id1);
        assertEq(d1, t.g1, "id1 not at g1");
        assertEq(vvd.getVotes(t.f1), 0, "f1 kept weight");
    }

    /// @dev Per-op record postconditions (same in both worlds).
    function _postconditions(TW memory t, uint256 zId) internal view {
        (address d,,,,) = vvd.delegations(t.id2);
        assertEq(d, t.a2, "post: id2 not back at a2");
        (d,,,,) = vvd.delegations(t.idS);
        assertEq(d, t.g3, "post: idS not at g3 (bySig then delegateAllFor)");
        (d,,,,) = vvd.delegations(t.id4);
        assertEq(d, t.buyer4, "post: id4 not at the buyer");
        (d,,,,) = vvd.delegations(zId);
        assertEq(d, t.dZ, "post: createLock not auto-delegated to dZ");
        uint48 e;
        (d, e,,,) = vvd.delegations(t.idK);
        assertEq(d, t.pK, "post: idK delegatee");
        assertGt(uint256(e), t.K, "post: idK record end not extended past K");
        (d,,,,) = vvd.delegations(t.idE);
        assertEq(d, address(0), "post: withdrawn idE record not deleted");
        for (uint256 i; i < 3; ++i) {
            (d,,,,) = vvd.delegations(t.bId[i]);
            assertEq(d, t.bA[i], "post: burst not undone");
        }
        (d,,,,) = vvd.delegations(t.bId[3]);
        assertEq(d, t.gb4, "post: burst id 3 not at gb4");
    }

    // tails: the elements a write can touch are the last two pre-existing and anything after.
    mapping(address => uint256) internal _tailFrom;

    function _recordTails(address[] memory ds) internal {
        for (uint256 i; i < ds.length; ++i) {
            uint256 len = uint256(vm.load(VVD_PROXY, _cpBase(ds[i])));
            _tailFrom[ds[i]] = len >= 2 ? len - 2 : 0;
        }
    }

    function _observeTails(address[] memory ds, uint256[] memory ids, uint256[] memory keys)
        internal
        view
        returns (bytes32[] memory items)
    {
        items = new bytes32[](ds.length * (1 + keys.length) + ids.length);
        uint256 n;
        for (uint256 i; i < ds.length; ++i) {
            bytes32 p = _cpBase(ds[i]);
            uint256 len = uint256(vm.load(VVD_PROXY, p));
            uint256 from = _tailFrom[ds[i]];
            bytes32[] memory w = new bytes32[](1 + 2 * (len - from));
            w[0] = bytes32(len);
            uint256 data = uint256(keccak256(abi.encode(p)));
            for (uint256 j = 2 * from; j < 2 * len; ++j) w[1 + j - 2 * from] = vm.load(VVD_PROXY, bytes32(data + j));
            items[n++] = keccak256(abi.encode(w));
            for (uint256 j; j < keys.length; ++j) items[n++] = _rawBucket(ds[i], keys[j]);
        }
        for (uint256 i; i < ids.length; ++i) {
            (bytes32 a, bytes32 b) = _rawRecord(ids[i]);
            items[n++] = keccak256(abi.encode(a, b));
        }
    }

    function test_writerPaths_twin() public {
        if (!live) return;
        TW memory t = _setup();
        _recordTails(_ds(t));
        uint256 snap = vm.snapshotState();
        Seen memory l = _world(t, false);
        vm.revertToState(snap);
        Seen memory w = _world(t, true);
        emit log_named_uint("window hour start h", t.h);
        emit log_named_uint("K (record end inside the window)", t.K);
        emit log_named_uint("DelegateVotesChanged events (L)", l.ev.length);
        emit log_named_uint("DelegateVotesChanged events (W)", w.ev.length);
        _assertSameObs(l.raw, w.raw, "twin");
        assertEq(l.ev.length, w.ev.length, "twin: event count");
        for (uint256 i; i < l.ev.length; ++i) {
            if (l.ev[i] != w.ev[i]) emit log_named_uint("twin: event mismatch at", i);
        }
        assertEq(keccak256(abi.encode(l.ev)), keccak256(abi.encode(w.ev)), "twin: DelegateVotesChanged stream differs");
        for (uint256 i; i < l.past.length; ++i) {
            if (l.past[i] != w.past[i]) emit log_named_uint("twin: getPastVotes mismatch at", i);
        }
        assertEq(keccak256(abi.encode(l.past)), keccak256(abi.encode(w.past)), "twin: getPastVotes lattice differs");
        assertEq(keccak256(abi.encode(l.hist)), keccak256(abi.encode(w.hist)), "twin: history differs");
    }

    struct PendingOnlyCase {
        uint256 idX; address oX; address aX;
        uint256 idY; address oY; address dY;
        address f; address g; uint256 h;
        address[] ds; uint256[] ids; uint256[] keys;
    }

    function _len1World(PendingOnlyCase memory c, bool window_) internal returns (bytes32[] memory raw, bytes32[] memory ev, uint256[16] memory past) {
        if (window_) _upgradeBoth();
        else _upgradeVeHemiOnly();
        vm.recordLogs();
        _to(c.h + 1223);
        vm.prank(c.oX);
        vvd.delegate(c.idX, c.f);
        _to(c.h + 1235);
        vm.prank(c.oY);
        vvd.delegate(c.idY, c.g);
        ev = _dvc(vm.getRecordedLogs());
        _to(c.h + 2 * HOUR + 11);
        raw = _observeTails(c.ds, c.ids, c.keys);
        uint256[4] memory ts = [c.h + 1224, c.h + 1236, c.h + HOUR - 1, c.h + HOUR + 1];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) past[i * 4 + j] = IVoteDelegationOps(VVD_PROXY).getPastVotes(c.ds[i], ts[j]);
        }
        assertApproxEqAbs(vvd.getVotes(c.f), veHemi.balanceOfNFT(c.idX), 1e12, "F after B != X");
        assertApproxEqAbs(vvd.getVotes(c.g), veHemi.balanceOfNFT(c.idY), 1e12, "G after B != Y");
    }

    /// len == 1 pending-only delegatee: the live writer books fresh F in the
    /// hour; in the window X moves A -> F, then F's live-booked record Y moves
    /// out to G. Twin-equal to the live writer, and after B the truth.
    function test_pendingOnly_len1_moveInMoveOut_twin() public {
        if (!live) return;
        PendingOnlyCase memory c;
        (c.idX, c.oX, c.aX) = _pick();
        (c.idY, c.oY, c.dY) = _pickFrom(c.idX + 1, 1e18);
        c.f = _addr("twin-len1-F");
        c.g = _addr("twin-len1-G");
        c.h = _nb(block.timestamp);
        _to(c.h + 611);
        vm.prank(c.oY);
        vvd.delegate(c.idY, c.f);
        assertEq(uint256(vm.load(VVD_PROXY, _cpBase(c.f))), 1, "premise: F is len 1");
        c.ds = new address[](4);
        c.ds[0] = c.aX; c.ds[1] = c.f; c.ds[2] = c.g; c.ds[3] = c.dY;
        _recordTails(c.ds);
        c.ids = new uint256[](2);
        c.ids[0] = c.idX; c.ids[1] = c.idY;
        c.keys = new uint256[](2);
        c.keys[0] = uint256(veHemi.getLockedBalance(c.idX).end);
        c.keys[1] = uint256(veHemi.getLockedBalance(c.idY).end);
        _to(c.h + 1211);
        uint256 snap = vm.snapshotState();
        (bytes32[] memory raw0, bytes32[] memory ev0, uint256[16] memory past0) = _len1World(c, false);
        vm.revertToState(snap);
        (bytes32[] memory raw1, bytes32[] memory ev1, uint256[16] memory past1) = _len1World(c, true);
        _assertSameObs(raw0, raw1, "len1");
        assertEq(keccak256(abi.encode(ev0)), keccak256(abi.encode(ev1)), "len1: events differ");
        for (uint256 i; i < 16; ++i) assertEq(past0[i], past1[i], "len1: getPastVotes differs");
    }
}
