// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./AutoRelockUpgradeForkBase.sol";

/**
 * The upgrade hour, on a fork. A PLAIN mid-hour upgrade of the VVD mixes the
 * deployed implementation's hour-boundary dating with the new implementation's
 * `t+1` dating inside one hour, and the sequences below then double-count (D2,
 * D5), panic (D1) or under-count (D1b). Each is re-run under the shipped batch
 * shape (`upgradeAndCall(VVD, impl, armLegacyDatingWindow())`) and must be
 * anomaly-free: D1, D1b and D2 at SEVEN execution instants of the hour
 * (`AutoRelockUpgradeForkBase._offsets`), D5 at three, with D3 as the
 * no-earlier-write control. The file also pins the arm value across the hour,
 * post-window equivalence with a fresh deployment, and the exact Safe batch
 * through `execTransaction`.
 */
contract UpgradeWindowForkTest is AutoRelockUpgradeForkBase {
    struct Run {
        uint256 id;
        address a;
        address fresh;
        uint256 w;
        uint256 boundary;
        uint256 tUp;
        uint256 votesA;
        uint256 votesACf;
        uint256 pastA;
        uint256 pastACf;
        uint256 pastAAfterB;
        uint256 votesAAfterB;
        uint256 votesAAfterBCf;
        uint256 freshInHour;
        uint256 freshAfterB;
    }

    /// @dev The D2 sequence: the deployed implementation retires the
    ///      record to `fresh` in-hour, the batch lands IN THE SAME BLOCK, and
    ///      the new implementation re-adds the record to A (12 s later, or
    ///      in the same block when `sameBlock_`, or at B+11 when the batch
    ///      landed at B-1).
    function _d2(uint256 offset_, bool preWrite_, bool sameBlock_) internal returns (Run memory r) {
        address owner;
        (r.id, owner, r.a) = _pick();
        r.fresh = address(uint160(uint256(keccak256("upgrade-hour-fresh"))));
        uint256 h = _nb(block.timestamp);
        _to(h + offset_);
        r.boundary = h + HOUR;
        r.w = veHemi.balanceOfNFT(r.id);

        uint256 snap = vm.snapshotState();
        _upgradeBoth();
        if (!sameBlock_) _to(block.timestamp + 12);
        _to(block.timestamp + 2);
        r.votesACf = vvd.getVotes(r.a);
        r.pastACf = vvd.getPastVotes(r.a, block.timestamp - 1);
        _toAfterB(r.boundary);
        r.votesAAfterBCf = vvd.getVotes(r.a);
        vm.revertToState(snap);

        if (preWrite_) {
            vm.prank(owner);
            vvd.delegate(r.id, r.fresh); // deployed implementation, in-hour
        }
        _upgradeBoth(); // same block
        r.tUp = block.timestamp;
        if (!sameBlock_) _to(block.timestamp + 12);
        vm.prank(owner);
        vvd.delegate(r.id, r.a); // new implementation
        _to(block.timestamp + 2);
        r.votesA = vvd.getVotes(r.a);
        r.pastA = vvd.getPastVotes(r.a, block.timestamp - 1);
        r.freshInHour = vvd.getVotes(r.fresh);
        _toAfterB(r.boundary);
        r.votesAAfterB = vvd.getVotes(r.a);
        r.pastAAfterB = vvd.getPastVotes(r.a, sameBlock_ ? r.tUp + 1 : r.tUp + 13);
        r.freshAfterB = vvd.getVotes(r.fresh);
        assertEq(vvd.delegation(r.id).delegatee, r.a, "D2: record not at A");
    }

    function _checkD2(Run memory r, string memory tag) internal pure {
        uint256 tol = r.w / 1e6 + 1e15;
        assertApproxEqAbs(r.votesA, r.votesACf, tol, string.concat(tag, ": double count in the window"));
        assertApproxEqAbs(r.pastA, r.pastACf, tol, string.concat(tag, ": getPastVotes shows a double count"));
        assertEq(r.pastAAfterB, r.pastA, string.concat(tag, ": history restated (re-read after B)"));
        assertApproxEqAbs(r.votesAAfterB, r.votesAAfterBCf, tol, string.concat(tag, ": after B"));
        assertEq(r.freshInHour, 0, string.concat(tag, ": from-delegatee holds weight in the window"));
        assertEq(r.freshAfterB, 0, string.concat(tag, ": from-delegatee holds weight after B"));
    }

    /// D2 (a plain mid-hour upgrade double-counts, frozen in history): no
    /// double count at ANY execution instant.
    function test_D2_reAddAfterLiveRetirement_noDoubleCount_anyInstant() public {
        if (!live) return;
        uint256[7] memory o = _offsets();
        for (uint256 i; i < o.length; ++i) {
            uint256 snap = vm.snapshotState();
            Run memory r = _d2(o[i], true, false);
            emit log_named_uint("offset", o[i]);
            emit log_named_uint("  A votes (window)", r.votesA);
            emit log_named_uint("  A votes counterfactual", r.votesACf);
            _checkD2(r, string.concat("D2@", vm.toString(o[i])));
            vm.revertToState(snap);
        }
    }

    /// D5 (a live write earlier in the SAME block as the batch): clean,
    /// including with the new implementation's re-add in that same block
    /// (the live-write / execTransaction / re-add sandwich).
    function test_D5_sameBlockSandwich_noDoubleCount() public {
        if (!live) return;
        uint256 snap = vm.snapshotState();
        _checkD2(_d2(11, true, false), "D5 first block");
        vm.revertToState(snap);
        _checkD2(_d2(11, true, true), "D5 sandwich");
        vm.revertToState(snap);
        _checkD2(_d2(1799, true, true), "D5 sandwich mid-hour");
        vm.revertToState(snap);
        _checkD2(_d2(3587, true, true), "D5 sandwich late hour");
    }

    /// D3 CONTROL: no earlier write in the hour.
    function test_D3_control_noEarlierWrite_noAnomaly() public {
        if (!live) return;
        Run memory r = _d2(1799, false, false);
        uint256 tol = r.w / 1e6 + 1e15;
        assertApproxEqAbs(r.votesA, r.votesACf, tol, "D3: in-window");
        assertApproxEqAbs(r.votesAAfterB, r.votesAAfterBCf, tol, "D3: after B");
    }

    /// D1 (after a plain upgrade: Panic(0x11), swallowed by VeHemi at every
    /// site). Retiring a pre-upgrade in-hour booking from a delegatee with NO
    /// live weight must succeed at every instant, with no weight at B ever and
    /// A whole.
    function _d1(uint256 offset_, bool doWrites_) internal returns (uint256 aIn, uint256 aPastAfterB, uint256 aAfterB, uint256 bIn, uint256 bAfterB, uint256 tProbe) {
        (uint256 id, address owner, address a) = _pick();
        address b = address(uint160(uint256(keccak256("upgrade-hour-B"))));
        uint256 h = _nb(block.timestamp);
        _to(h + 60);
        vm.prank(owner);
        vvd.delegate(id, b);
        _to(h + HOUR + 60);
        vm.prank(owner);
        vvd.delegate(id, a);
        uint256 boundary = h + 3 * HOUR;
        _to(h + 2 * HOUR + offset_);
        if (doWrites_) {
            vm.prank(owner);
            vvd.delegate(id, b); // deployed writer, in the upgrade hour
            assertEq(vvd.getVotes(b), 0, "D1: premise -- B holds no live weight");
        }
        _upgradeBoth();
        _nextBlockOrSame(boundary);
        if (doWrites_) {
            vm.prank(owner);
            vvd.delegate(id, a); // Panic(0x11) after a plain upgrade
            assertEq(vvd.delegation(id).delegatee, a, "D1: record not at A");
        }
        _to(block.timestamp + 2);
        tProbe = block.timestamp - 1;
        aIn = vvd.getVotes(a);
        bIn = vvd.getVotes(b);
        _to(boundary + 11);
        aAfterB = vvd.getVotes(a);
        bAfterB = vvd.getVotes(b);
        aPastAfterB = vvd.getPastVotes(a, tProbe);
    }

    function test_D1_retireInHourBooking_noPanic_anyInstant() public {
        if (!live) return;
        uint256[7] memory o = _offsets();
        for (uint256 i; i < o.length; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 cfIn, uint256 cfPast, uint256 cfAfter,,,) = _d1(o[i], false);
            vm.revertToState(snap);
            (uint256 aIn, uint256 aPast, uint256 aAfter, uint256 bIn, uint256 bAfter,) = _d1(o[i], true);
            vm.revertToState(snap);
            string memory tag = string.concat("D1@", vm.toString(o[i]));
            emit log_named_uint("offset", o[i]);
            emit log_named_uint("  A votes (window)", aIn);
            emit log_named_uint("  A votes counterfactual", cfIn);
            uint256 tol = cfIn / 1e6 + 1e15;
            assertApproxEqAbs(aIn, cfIn, tol, string.concat(tag, ": A in the window"));
            assertApproxEqAbs(aPast, cfPast, tol, string.concat(tag, ": A history read after B"));
            assertApproxEqAbs(aAfter, cfAfter, tol, string.concat(tag, ": A after B"));
            assertEq(bIn, 0, string.concat(tag, ": B in the window"));
            assertEq(bAfter, 0, string.concat(tag, ": B after B"));
        }
    }

    struct RetireRig {
        uint256 x;
        address xOwner;
        address a;
        uint256 w;
        uint256 y;
        address yOwner;
        address b2;
        uint256 boundary;
    }

    /// @dev The D1b rig at an arbitrary booking-and-batch offset.
    function _retirePath(RetireRig memory k, bool bookX_) internal returns (uint256 inHour, uint256 afterB, bool reverted) {
        if (bookX_) {
            vm.prank(k.xOwner);
            vvd.delegate(k.x, k.b2); // deployed writer, in the upgrade hour
        }
        _upgradeBoth();
        _nextBlockOrSame(k.boundary);
        if (bookX_) {
            vm.prank(k.xOwner);
            try vvd.delegate(k.x, k.a) {} catch { reverted = true; }
        }
        _to(block.timestamp + 2);
        inHour = vvd.getVotes(k.b2);
        _to(k.boundary + 11);
        afterB = vvd.getVotes(k.b2);
    }

    function test_D1b_retireInHourBooking_noUnderCount_anyInstant() public {
        if (!live) return;
        uint256[7] memory o = _offsets();
        RetireRig memory k;
        (k.x, k.xOwner, k.a) = _pick();
        k.w = veHemi.balanceOfNFT(k.x);
        (k.y, k.yOwner, ) = _pickFrom(k.x + 1, 3 * k.w);
        k.b2 = address(uint160(uint256(keccak256("upgrade-hour-B2"))));
        uint256 h = _nb(block.timestamp);
        _to(h + 60);
        vm.prank(k.yOwner);
        vvd.delegate(k.y, k.b2); // live at B2 from h + HOUR
        k.boundary = h + 2 * HOUR;
        for (uint256 i; i < o.length; ++i) {
            uint256 snap = vm.snapshotState();
            _to(h + HOUR + o[i]);
            uint256 s2 = vm.snapshotState();
            (uint256 cfIn, uint256 cfAfter, ) = _retirePath(k, false);
            vm.revertToState(s2);
            (uint256 inHour, uint256 afterB, bool reverted) = _retirePath(k, true);
            vm.revertToState(snap);
            string memory tag = string.concat("D1b@", vm.toString(o[i]));
            uint256 tol = k.w / 1e6 + 1e15;
            assertFalse(reverted, string.concat(tag, ": retirement reverted"));
            assertApproxEqAbs(inHour, cfIn, tol, string.concat(tag, ": B2 in the window"));
            assertApproxEqAbs(afterB, cfAfter, tol, string.concat(tag, ": B2 after B"));
        }
    }

    /// The arm value across the hour (k = 0, 1, 149, 298, 299): W == B for a
    /// batch at h + 12k + 11, the event says (B, true), and at k = 299 (B-1)
    /// the first write after B is immediate.
    function test_armValue_everyPhase() public {
        if (!live) return;
        uint256 h = _nb(block.timestamp);
        uint256[5] memory ks = [uint256(0), 1, 149, 298, 299];
        for (uint256 i; i < ks.length; ++i) {
            uint256 snap = vm.snapshotState();
            _to(h + 12 * ks[i] + 11);
            vm.recordLogs();
            _upgradeBoth();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bytes32 t = keccak256("LegacyDatingWindowArmed(uint256,bool)");
            bool seen;
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].emitter == VVD_PROXY && logs[j].topics[0] == t) {
                    (uint256 until, bool via) = abi.decode(logs[j].data, (uint256, bool));
                    assertEq(until, h + HOUR, "arm event: until");
                    assertTrue(via, "arm event: viaUpgradeCall");
                    seen = true;
                }
            }
            assertTrue(seen, "arm event missing");
            assertEq(uint256(vvd.legacyDatingUntil()), h + HOUR, "arm: W != B");
            assertEq(vvd.legacyDatingActive(), ks[i] != 299, "legacyDatingActive (false only at B-1)");
            if (ks[i] == 299) {
                (uint256 id, address owner, ) = _pick();
                _to(h + HOUR + 11);
                vm.prank(owner);
                vvd.delegate(id, address(uint160(uint256(keccak256("upgrade-hour-k299")))));
                assertEq(uint256(vvd.delegationBookedAt(id)), block.timestamp + 1, "post-B write not immediate");
            }
            vm.revertToState(snap);
        }
    }

    /// Post-B equivalence: after the window, writes are immediate (stamp
    /// now + 1, element at now + 1) and the result equals the same ops on a
    /// twin whose slot 101 was overwritten to the fresh-deployment sentinel 1.
    struct PB {
        uint256 id1;
        address o1;
        address a1;
        uint256 id2;
        address o2;
        address a2;
        address g;
    }

    function _postBOps(PB memory p) internal returns (bytes32[] memory ev) {
        vm.recordLogs();
        vm.prank(p.o1);
        vvd.delegate(p.id1, p.g);
        assertEq(uint256(vvd.delegationBookedAt(p.id1)), block.timestamp + 1, "post-B stamp != now + 1");
        _to(block.timestamp + 12);
        vm.prank(p.o2);
        vvd.delegate(p.id2, p.g);
        vm.prank(p.o1);
        vvd.delegate(p.id1, p.a2);
        try vvd.writeNewCheckpointForExpiredDelegations(p.a1) {} catch {} // NoExpirations is fine
        vvd.refreshVotingPower(p.g);
        ev = _dvc(vm.getRecordedLogs());
    }

    function test_postB_equivalence() public {
        if (!live) return;
        uint256 h = _nb(block.timestamp);
        _to(h + 1211);
        _upgradeBoth();
        _to(h + HOUR + 11);
        assertFalse(vvd.legacyDatingActive(), "window still active after B");
        PB memory p;
        (p.id1, p.o1, p.a1) = _pick();
        (p.id2, p.o2, p.a2) = _pickFrom(p.id1 + 1, 1e18);
        p.g = address(uint160(uint256(keccak256("upgrade-hour-postB-g"))));
        address[] memory ds = new address[](3);
        ds[0] = p.a1; ds[1] = p.a2; ds[2] = p.g;
        uint256[] memory ids = new uint256[](2);
        ids[0] = p.id1; ids[1] = p.id2;
        uint256[] memory keys = new uint256[](2);
        keys[0] = uint256(veHemi.getLockedBalance(p.id1).end);
        keys[1] = uint256(veHemi.getLockedBalance(p.id2).end);

        uint256 snap = vm.snapshotState();
        bytes32[] memory ev0 = _postBOps(p);
        bytes32[] memory obs0 = _observe(ds, ids, keys);
        vm.revertToState(snap);
        vm.store(VVD_PROXY, bytes32(uint256(101)), bytes32(uint256(1)));
        bytes32[] memory ev1 = _postBOps(p);
        bytes32[] memory obs1 = _observe(ds, ids, keys);
        _assertSameObs(obs0, obs1, "postB");
        assertEq(keccak256(abi.encode(ev0)), keccak256(abi.encode(ev1)), "postB: events differ");
    }

    /// Batch fidelity: the EXACT MultiSendCallOnly payload through
    /// Safe.execTransaction (owners' approveHash, v = 1), mid-hour, with a
    /// live write EARLIER in the same block and a new-implementation write
    /// LATER in it.
    function test_batchFidelity_execTransaction() public {
        if (!live) return;
        assertGt(MULTISEND_CALL_ONLY.code.length, 0, "MultiSendCallOnly 1.4.1 absent at the fork block");
        _impls();
        (uint256 id, address owner, address a) = _pick();
        address fresh = address(uint160(uint256(keccak256("upgrade-hour-fid-fresh"))));
        uint256 h = _nb(block.timestamp);
        _to(h + 1799);
        uint256 w = veHemi.balanceOfNFT(id);

        bytes memory leg0 = abi.encodeCall(IForkProxyAdmin.upgrade, (VEHEMI_PROXY, newVeHemiImpl));
        bytes memory leg1 = abi.encodeCall(IForkProxyAdmin.upgradeAndCall, (VVD_PROXY, newVvdImpl, _armData()));
        bytes memory txs = abi.encodePacked(
            uint8(0), PROXY_ADMIN, uint256(0), leg0.length, leg0,
            uint8(0), PROXY_ADMIN, uint256(0), leg1.length, leg1
        );
        bytes memory data = abi.encodeWithSignature("multiSend(bytes)", txs);

        // Counterfactual: the batch alone, same block.
        uint256 snap = vm.snapshotState();
        _execSafe(data);
        _to(block.timestamp + 2);
        uint256 cfA = vvd.getVotes(a);
        _to(h + HOUR + 11);
        uint256 cfAfter = vvd.getVotes(a);
        vm.revertToState(snap);

        vm.prank(owner);
        vvd.delegate(id, fresh); // live write, same block, before the batch
        _execSafe(data);
        assertEq(uint256(vvd.legacyDatingUntil()), h + HOUR, "fidelity: window not armed by the Safe batch");
        assertEq(address(uint160(uint256(vm.load(VVD_PROXY, IMPL_SLOT)))), newVvdImpl, "fidelity: VVD impl");
        assertEq(address(uint160(uint256(vm.load(VEHEMI_PROXY, IMPL_SLOT)))), newVeHemiImpl, "fidelity: VeHemi impl");
        vm.prank(owner);
        vvd.delegate(id, a); // new-implementation write, same block, after the batch
        _to(block.timestamp + 2);
        uint256 tol = w / 1e6 + 1e15;
        assertApproxEqAbs(vvd.getVotes(a), cfA, tol, "fidelity: A in the window");
        assertEq(vvd.getVotes(fresh), 0, "fidelity: fresh in the window");
        _to(h + HOUR + 11);
        assertApproxEqAbs(vvd.getVotes(a), cfAfter, tol, "fidelity: A after B");
        assertEq(vvd.getVotes(fresh), 0, "fidelity: fresh after B");
    }

    function _execSafe(bytes memory data) internal {
        (bool ok, bytes memory ret) = SAFE.staticcall(abi.encodeWithSignature("getOwners()"));
        require(ok, "getOwners");
        address[] memory owners = abi.decode(ret, (address[]));
        (ok, ret) = SAFE.staticcall(abi.encodeWithSignature("getThreshold()"));
        uint256 threshold = abi.decode(ret, (uint256));
        (ok, ret) = SAFE.staticcall(abi.encodeWithSignature("nonce()"));
        uint256 nonce = abi.decode(ret, (uint256));
        (ok, ret) = SAFE.staticcall(
            abi.encodeWithSignature(
                "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)",
                MULTISEND_CALL_ONLY, uint256(0), data, uint8(1), uint256(0), uint256(0), uint256(0), address(0), address(0), nonce
            )
        );
        bytes32 txHash = abi.decode(ret, (bytes32));
        // threshold owners, ascending
        address[] memory s = new address[](threshold);
        for (uint256 i; i < threshold; ++i) s[i] = owners[i];
        for (uint256 i; i < threshold; ++i) {
            for (uint256 j = i + 1; j < threshold; ++j) {
                if (s[j] < s[i]) (s[i], s[j]) = (s[j], s[i]);
            }
        }
        bytes memory sigs;
        for (uint256 i; i < threshold; ++i) {
            vm.prank(s[i]);
            (ok, ) = SAFE.call(abi.encodeWithSignature("approveHash(bytes32)", txHash));
            require(ok, "approveHash");
            sigs = abi.encodePacked(sigs, bytes32(uint256(uint160(s[i]))), bytes32(0), uint8(1));
        }
        vm.recordLogs();
        (ok, ret) = SAFE.call(
            abi.encodeWithSignature(
                "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                MULTISEND_CALL_ONLY, uint256(0), data, uint8(1), uint256(0), uint256(0), uint256(0), address(0), payable(address(0)), sigs
            )
        );
        require(ok && abi.decode(ret, (bool)), "execTransaction");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, SAFE, keccak256("ExecutionSuccess(bytes32,uint256)")), 1, "Safe: no ExecutionSuccess");
    }
}
