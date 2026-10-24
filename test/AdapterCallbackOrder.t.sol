// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";

/// A conforming stand-in for `VeHemiAragonAdapter` that, like the real
/// adapter, READS THE DELEGATION RECORD BACK inside `notifyDelegateChanged`
/// (the shipped adapter walks every position of `delegator` and reads
/// `delegation(tokenId).delegatee` there, to decide whether the post-change
/// state is account-wide consistent). It also records the callback order.
contract CallbackOrderAdapter {
    /// 1 = notifyDelegateChanged, 2 = notifyVotesChanged.
    uint8[] public order;
    VeHemiVoteDelegation public d;
    uint256 public probeId;
    address public seenDelegateeAtCallback;
    bool public probed;
    function arm(VeHemiVoteDelegation d_, uint256 id_) external { d = d_; probeId = id_; }
    function notifyVotesChanged(address, uint256, uint256) external { order.push(2); }
    function notifyDelegateChanged(address, address, address) external {
        order.push(1);
        if (address(d) != address(0)) {
            (address dg,,,,) = d.delegations(probeId);
            seenDelegateeAtCallback = dg;
            probed = true;
        }
    }
    function len() external view returns (uint256) { return order.length; }
    function clear() external { delete order; probed = false; seenDelegateeAtCallback = address(0); }
}

/// Event ordering. On every `_delegate`-reachable path VVD emits
/// `DelegateChanged` before `DelegateVotesChanged` (the OpenZeppelin
/// `Votes._delegate` / ERC-5805 order), and the adapter relay fires after the
/// delegation record has been written.
contract AdapterCallbackOrderTest is LockedCurveTestBase {
    CallbackOrderAdapter internal adapter;

    bytes32 constant DC  = keccak256("DelegateChanged(uint256,address,address)");
    bytes32 constant DVC = keccak256("DelegateVotesChanged(address,uint256,uint256)");

    uint256 internal covered;   // how many distinct paths actually asserted

    function setUp() public override {
        super.setUp();
        adapter = new CallbackOrderAdapter();
    }

    function _mk(address who, uint256 amt, uint256 dur) internal returns (uint256 id) {
        hemi.mint(who, amt);
        vm.startPrank(who);
        hemi.approve(address(veHemi), type(uint256).max);
        id = veHemi.createLock(amt, dur);
        vm.stopPrank();
    }

    /// The whole assertion, in one place: within the logs emitted by VVD since
    /// the last `vm.recordLogs()`, the FIRST `DelegateChanged` must precede the
    /// FIRST `DelegateVotesChanged`.  Both must be present -- a path that emits
    /// only one of them proves nothing and is refused, not skipped.
    function _assertOrder(string memory label) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256 iDC = -1;
        int256 iDVC = -1;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(delegation) || logs[i].topics.length == 0) continue;
            if (iDC  == -1 && logs[i].topics[0] == DC)  iDC  = int256(i);
            if (iDVC == -1 && logs[i].topics[0] == DVC) iDVC = int256(i);
        }
        emit log_named_string("path", label);
        emit log_named_int("   first DelegateChanged      log index", iDC);
        emit log_named_int("   first DelegateVotesChanged  log index", iDVC);
        assertGt(iDC,  -1, string.concat(label, ": NO DelegateChanged -- the body cannot pin an order"));
        assertGt(iDVC, -1, string.concat(label, ": NO DelegateVotesChanged -- the body cannot pin an order"));
        assertLt(iDC, iDVC, string.concat(
            label, ": DelegateVotesChanged precedes DelegateChanged. OpenZeppelin's "
            "Votes._delegate -- the ERC-5805 reference the Aragon tooling reads -- emits "
            "DelegateChanged FIRST."
        ));
        covered += 1;
    }

    // ── EVERY `_delegate`-REACHABLE PATH ─────────────────────────────────────

    function test_plainReDelegation() public {
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.recordLogs();
        vm.prank(alice); delegation.delegate(id, charlie);
        _assertOrder("plain re-delegation");
        assertEq(covered, 1, "the assertion did not run");
    }

    function test_sameDelegateeReDelegation() public {
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.recordLogs();
        vm.prank(alice); delegation.delegate(id, bob);      // SAME delegatee
        _assertOrder("same-delegatee re-delegation");
        assertEq(covered, 1, "the assertion did not run");
    }

    function test_enableAutoRelock() public {
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.recordLogs();
        vm.prank(alice); veHemi.enableAutoRelock(id);
        _assertOrder("enableAutoRelock");
        assertEq(covered, 1, "the assertion did not run");
    }

    function test_disableAutoRelock() public {
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.prank(alice); veHemi.enableAutoRelock(id);
        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        vm.prank(alice); veHemi.disableAutoRelock(id);
        _assertOrder("disableAutoRelock");
        assertEq(covered, 1, "the assertion did not run");
    }

    function test_retireStaleAutoRelock() public {
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.prank(alice); veHemi.enableAutoRelock(id);
        vm.warp(block.timestamp + 400 days);
        vm.recordLogs();
        veHemi.retireStaleAutoRelock(id);                   // permissionless, by design
        _assertOrder("retireStaleAutoRelock");
        assertEq(covered, 1, "the assertion did not run");
    }

    function test_zeroDelegateeCleanupOnWithdraw() public {
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp(veHemi.getLockedBalance(id).end + 1);
        vm.recordLogs();
        vm.prank(alice); veHemi.withdraw(id);               // _delegate(id, address(0))
        _assertOrder("delegatee == address(0) cleanup (withdraw)");
        assertEq(covered, 1, "the assertion did not run");
    }

    function test_zeroDelegateeCleanupOnForfeit() public {
        hemi.mint(address(this), 500 ether);
        hemi.approve(address(veHemi), type(uint256).max);
        // A forfeitable (and therefore non-transferable) position: `forfeit`
        // refuses anything else, and the cleanup leg is what is under test.
        uint256 id = veHemi.createLockFor(500 ether, 7 * SIX_DAYS, alice, false, true);
        vm.prank(alice); delegation.delegate(id, bob);
        vm.warp(block.timestamp + 3 * SIX_DAYS);
        veHemi.updateForfeitAdmin(address(this));   // `forfeit` is admin-gated
        vm.recordLogs();
        veHemi.forfeit(id);
        _assertOrder("delegatee == address(0) cleanup (forfeit)");
        assertEq(covered, 1, "the assertion did not run");
    }

    // ── THE ADAPTER RELAY ────────────────────────────────────────────────────

    /// The relay is a separate call site from the log and keeps its own order:
    /// `VeHemiAragonAdapter.notifyDelegateChanged` reads the
    /// delegation record back to resolve the account-wide delegatee, so it
    /// must fire after `delegations[delegator_] = ...`, or it would read the
    /// pre-change state. This body pins both halves:
    ///   (1) the callback arrives `votes` first, by design;
    ///   (2) at the instant `notifyDelegateChanged` fires, the delegation
    ///       record ALREADY carries the NEW delegatee (the load-bearing one).
    /// Consequence: the adapter's own re-emitted logs (the ones Aragon's
    /// subgraph indexes) keep the `votes, delegate` order; the OpenZeppelin
    /// order holds on VVD's logs.
    function test_adapterRelayStaysAfterTheStateWrite() public {
        veHemi.transferOwnership(address(this));
        delegation.setTrustedAdapter(address(adapter));
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        adapter.clear();
        adapter.arm(delegation, id);

        vm.recordLogs();
        vm.prank(alice); delegation.delegate(id, charlie);

        uint256 n = adapter.len();
        assertGt(n, 1, "the relay never fired both callbacks -- nothing to order");
        for (uint256 i = 0; i < n; ++i) {
            emit log_named_uint("relay callback (1=delegate 2=votes)", adapter.order(i));
        }
        assertTrue(adapter.probed(), "the callback never read the record back");
        emit log_named_address("delegatee seen INSIDE notifyDelegateChanged", adapter.seenDelegateeAtCallback());
        assertEq(
            adapter.seenDelegateeAtCallback(), charlie,
            "notifyDelegateChanged fired BEFORE the delegation record was written. "
            "VeHemiAragonAdapter resolves the account-wide delegatee by reading this record, "
            "so it would advertise the OLD delegatee. The relay must stay after the state write."
        );
        assertEq(
            uint256(adapter.order(0)), 2,
            "the relay order changed. It is deliberately `votes, delegate` -- see this body's doc."
        );
        // and the LOG stream, in the same call, leads with DelegateChanged
        _assertOrder("adapter-relay call (log stream)");
    }

    /// The one path where the relay's `veHemi.ownerOf(delegator_)` could
    /// matter: the burn/cleanup leg, with a trusted adapter installed. The
    /// relay resolves the owner inside its own try/catch, so if the token were
    /// already burned when it does, the relay would be skipped silently and
    /// the callbacks asserted below would never arrive.
    function test_burnCleanupWithAdapterInstalled() public {
        veHemi.transferOwnership(address(this));
        delegation.setTrustedAdapter(address(adapter));
        uint256 id = _mk(alice, 500 ether, 7 * SIX_DAYS);
        vm.prank(alice); delegation.delegate(id, bob);
        adapter.clear();
        vm.warp(veHemi.getLockedBalance(id).end + 1);

        adapter.arm(delegation, id);
        vm.recordLogs();
        vm.prank(alice); veHemi.withdraw(id);               // burns the NFT
        assertGt(adapter.len(), 1, "the relay did not fire on the cleanup leg");
        assertTrue(adapter.probed(), "the callback never read the record back");
        // On the cleanup leg the record is DELETED before the relay fires, for
        // the same reason: the adapter must see the settled post-state.
        assertEq(
            adapter.seenDelegateeAtCallback(), address(0),
            "notifyDelegateChanged fired BEFORE the cleanup delete -- the adapter would "
            "miss the forfeit/withdraw close-out (test_relay_onForfeit_nearExpiry)."
        );
        assertEq(uint256(adapter.order(0)), 2, "relay order changed on the cleanup leg");
        _assertOrder("burn cleanup with adapter installed");
    }
}
