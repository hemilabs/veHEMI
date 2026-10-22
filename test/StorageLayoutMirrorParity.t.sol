// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "./LockedCurveTestBase.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title StorageLayoutMirrorParityTest
///
/// @notice `src/lib/VeHemiLayout.sol` is a second source of truth for the VeHemi
///         proxy's storage: a DELEGATECALL library cannot inherit
///         `VeHemiStorageV3`, so the whole layout is duplicated as a
///         slot-0-anchored struct. A one-word drift there
///         (`uint256[37] __gapV2` -> `[38]`) compiles, leaves the VeHemi runtime
///         unchanged and passes every fixture-based layout check, while every
///         library access to slot 64+ lands one slot off (the libraries would
///         read R from a slot VeHemi never writes it to). This suite holds the
///         mirror to VeHemi's layout inside `forge test`.
///
/// @dev    TWO INDEPENDENT LAYERS.
///
///         LAYER A (static, total): the members of `t_struct(VeHemiLayout)` in
///         the COMPILED probe artifact vs the committed VeHemi layout, member
///         for member, in order: label / slot / offset / a RECURSIVE canonical
///         type rendering (solc's human-readable type `label` + `encoding` +
///         `numberOfBytes`, descending through struct members, array bases and
///         mapping key/value). No AST ids (so unrelated edits cannot
///         false-positive), array lengths and integer widths preserved (so
///         `[37]`->`[38]`, `[1e9]`->`[1e8]` and `uint64`->`uint128` are all
///         visible). One deliberate equivalence: `contract IFoo` == `address`.
///
///         LAYER B (runtime): the expected slot is read from the committed
///         layout, never from the mirror. VeHemi itself writes R and the
///         heartbeat through its own compiled layout; the libraries only READ R
///         (`VeHemiCurveLib.sol::checkpoint` reads `autoRelockRemaining` through
///         the mirror and builds the flat user point from it).
///         - `test_VeHemiWritesRAtTheDeclaredSlot` and
///           `test_RLandsOnNeitherNeighbouringSlot` pin where VeHemi stores R
///           and the stamp. They pin VeHemi's layout and cannot see a mirror
///           drift.
///         - `test_LibraryReadsRFromTheDeclaredSlot` plants a sentinel R at the
///           declared slot and different sentinels one slot either side, forces
///           a user checkpoint, and requires the flat bias to come from the
///           declared slot's sentinel. A one-word mirror drift makes the
///           library read a neighbour and fails it, and so does an anchor
///           drift in `VeHemiCurveLib` (`l.slot := 1`), which Layer A cannot
///           see (`scripts/check-library-layout-mirror.sh` gates the anchors).
contract StorageLayoutMirrorParityTest is LockedCurveTestBase {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @dev The committed layout fixture (15 KB), not `out/VeHemi.sol/VeHemi.json`
    ///      (over 400 KB): every cheatcode call re-copies the whole string into
    ///      memory, and a recursive walk over the artifact runs out of memory
    ///      under Foundry's default limit. The fixture has the same
    ///      `.storage`/`.types` shape and is held to the compiled VeHemi artifact
    ///      by `StorageLayoutCompiledParity.t.sol` and `scripts/check-storage-layouts.sh`.
    string internal constant VEHEMI_LAYOUT = "test/fixtures/storage-layouts/VeHemi.json";
    string internal constant PROBE = "out/VeHemiLayoutProbe.sol/VeHemiLayoutProbe.json";

    /// @dev anti-vacuity floor; the real layout has 29 top-level entries
    ///      (deployed 26 + 3 appended, asserted by
    ///      `StorageLayoutOnchainAnchor.t.sol::test_AutoRelockAppendsExactlyThreeVeHemiEntriesAndNothingElse`).
    uint256 internal constant MIN_MEMBERS = 25;

    string internal veHemiJson;
    string internal probeJson;
    string internal mirrorTypeKey;

    function setUp() public override {
        super.setUp();
        veHemiJson = vm.readFile(VEHEMI_LAYOUT);
        probeJson = vm.readFile(PROBE);
        assertTrue(vm.keyExistsJson(veHemiJson, ".storage"), "VeHemi layout fixture has no .storage");
        assertTrue(
            vm.keyExistsJson(probeJson, ".storageLayout"),
            "probe artifact carries no storageLayout: run forge clean && forge build (foundry.toml needs extra_output=[storageLayout])"
        );
        mirrorTypeKey = _findMirrorTypeKey();
    }

    // ───────────────────────────── json helpers ─────────────────────────────

    function probeIndex(string calldata json, string calldata path) external view returns (string memory) {
        return vm.parseJsonString(json, path);
    }

    function _exists(string memory json, string memory path) internal view returns (bool) {
        try this.probeIndex(json, path) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _str(string memory json, string memory path) internal view returns (string memory) {
        return vm.parseJsonString(json, path);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory bs = bytes(s);
        bytes memory bp = bytes(p);
        if (bs.length < bp.length) return false;
        for (uint256 i; i < bp.length; ++i) {
            if (bs[i] != bp[i]) return false;
        }
        return true;
    }

    /// @dev the fixture is a bare layout; the artifact nests it under `.storageLayout`.
    function _rootOf(bool isProbe) internal pure returns (string memory) {
        return isProbe ? ".storageLayout" : "";
    }

    function _typePath(bool isProbe, string memory typeKey) internal pure returns (string memory) {
        return string.concat(_rootOf(isProbe), ".types.['", typeKey, "']");
    }

    function _findMirrorTypeKey() internal view returns (string memory) {
        string[] memory keys = vm.parseJsonKeys(probeJson, ".storageLayout.types");
        for (uint256 i; i < keys.length; ++i) {
            if (_startsWith(keys[i], "t_struct(VeHemiLayout)")) return keys[i];
        }
        revert("VeHemiLayout struct absent from the probe artifact: the mirror is uninspectable");
    }

    /// @dev a child type reference, or "" when the key is absent or JSON null.
    function _child(string memory json, string memory path) internal view returns (string memory) {
        if (!_exists(json, path)) return "";
        string memory v = _str(json, path);
        if (_eq(v, "null")) return "";
        return v;
    }

    /// @dev one struct member, rendered. Split out of `_canon` purely to keep
    ///      the stack shallow enough for the non-via-ir CI profile.
    function _memberOf(bool isProbe, string memory json, string memory m, uint256 depth)
        internal
        view
        returns (string memory)
    {
        string memory head = string.concat(
            _str(json, string.concat(m, ".label")),
            "@",
            _str(json, string.concat(m, ".slot")),
            ":",
            vm.toString(vm.parseJsonUint(json, string.concat(m, ".offset"))),
            "="
        );
        return string.concat(head, _canon(isProbe, json, _str(json, string.concat(m, ".type")), depth));
    }

    /// @notice Recursive canonical rendering of one type entry.
    function _canon(bool isProbe, string memory json, string memory typeKey, uint256 depth)
        internal
        view
        returns (string memory)
    {
        string memory base = _typePath(isProbe, typeKey);
        if (!_exists(json, string.concat(base, ".label"))) return string.concat("MISSING_TYPE(", typeKey, ")");
        if (depth == 0) return "DEPTH_LIMIT";

        string memory label = _str(json, string.concat(base, ".label"));
        if (_startsWith(label, "contract ")) label = "address";
        string memory acc = string.concat(
            label, "|", _str(json, string.concat(base, ".encoding")), "|", _str(json, string.concat(base, ".numberOfBytes"))
        );

        if (_exists(json, string.concat(base, ".members[0].label"))) {
            acc = string.concat(acc, "{");
            for (uint256 i; i < 64; ++i) {
                string memory m = string.concat(base, ".members[", vm.toString(i), "]");
                if (!_exists(json, string.concat(m, ".label"))) break;
                if (i > 0) acc = string.concat(acc, ",");
                acc = string.concat(acc, _memberOf(isProbe, json, m, depth - 1));
            }
            acc = string.concat(acc, "}");
        }
        // `scripts/_normalize-storage-layout.sh` writes an explicit `null` for
        // `base`/`key`/`value` on type entries that have none (jq's `.x? |=`
        // creates the key), so "absent" has to mean "absent OR null".
        string memory child = _child(json, string.concat(base, ".base"));
        if (bytes(child).length != 0) acc = string.concat(acc, "[base=", _canon(isProbe, json, child, depth - 1), "]");
        child = _child(json, string.concat(base, ".key"));
        if (bytes(child).length != 0) acc = string.concat(acc, "[key=", _canon(isProbe, json, child, depth - 1), "]");
        child = _child(json, string.concat(base, ".value"));
        if (bytes(child).length != 0) acc = string.concat(acc, "[val=", _canon(isProbe, json, child, depth - 1), "]");
        return acc;
    }

    function _veHemiRow(uint256 i) internal view returns (string memory row, bool ok) {
        string memory e = string.concat(".storage[", vm.toString(i), "]");
        if (!_exists(veHemiJson, string.concat(e, ".label"))) return ("", false);
        row = string.concat(
            _str(veHemiJson, string.concat(e, ".label")),
            " @slot ",
            _str(veHemiJson, string.concat(e, ".slot")),
            " off ",
            vm.toString(vm.parseJsonUint(veHemiJson, string.concat(e, ".offset"))),
            " : ",
            _canon(false, veHemiJson, _str(veHemiJson, string.concat(e, ".type")), 8)
        );
        ok = true;
    }

    function _mirrorRow(uint256 i) internal view returns (string memory row, bool ok) {
        string memory m = string.concat(_typePath(true, mirrorTypeKey), ".members[", vm.toString(i), "]");
        if (!_exists(probeJson, string.concat(m, ".label"))) return ("", false);
        row = string.concat(
            _str(probeJson, string.concat(m, ".label")),
            " @slot ",
            _str(probeJson, string.concat(m, ".slot")),
            " off ",
            vm.toString(vm.parseJsonUint(probeJson, string.concat(m, ".offset"))),
            " : ",
            _canon(true, probeJson, _str(probeJson, string.concat(m, ".type")), 8)
        );
        ok = true;
    }

    /// @dev slot of a VeHemi state variable, taken from the committed layout.
    function _declaredSlot(string memory label) internal view returns (uint256) {
        for (uint256 i; i < 256; ++i) {
            string memory e = string.concat(".storage[", vm.toString(i), "]");
            if (!_exists(veHemiJson, string.concat(e, ".label"))) break;
            if (_eq(_str(veHemiJson, string.concat(e, ".label")), label)) {
                return vm.parseUint(_str(veHemiJson, string.concat(e, ".slot")));
            }
        }
        revert(string.concat("VeHemi layout declares no state variable named ", label));
    }

    // ──────────────────────────── LAYER A ───────────────────────────────────

    /// @notice The probe must really be ONE mirror struct at slot 0, or every
    ///         number below describes something other than what the libraries see.
    function test_ProbeIsASingleMirrorAtSlotZero() public view {
        assertTrue(_exists(probeJson, ".storageLayout.storage[0].label"), "probe has no storage");
        assertFalse(_exists(probeJson, ".storageLayout.storage[1].label"), "probe has more than one state variable");
        assertEq(_str(probeJson, ".storageLayout.storage[0].slot"), "0", "probe mirror is not at slot 0");
        assertEq(vm.parseJsonUint(probeJson, ".storageLayout.storage[0].offset"), 0, "probe mirror is not at offset 0");
        assertTrue(
            _startsWith(_str(probeJson, ".storageLayout.storage[0].type"), "t_struct(VeHemiLayout)"),
            "probe state variable is not a VeHemiLayout"
        );
    }

    /// @notice NOT-VACUOUS GUARD. A missing `.storageLayout` (stale incremental
    ///         artifact) would make every comparison below pass on nothing.
    function test_ParityIsNotVacuous() public view {
        uint256 n;
        while (true) {
            (, bool ok) = _veHemiRow(n);
            if (!ok) break;
            ++n;
        }
        uint256 m;
        while (true) {
            (, bool ok) = _mirrorRow(m);
            if (!ok) break;
            ++m;
        }
        assertGe(n, MIN_MEMBERS, "VeHemi side rendered too few entries: stale or empty");
        assertGe(m, MIN_MEMBERS, "mirror side rendered too few members: stale or empty");
    }

    /// @notice THE GATE. Member for member, in order, types included.
    function test_MirrorMatchesVeHemiLayout() public {
        uint256 i;
        while (true) {
            (string memory a, bool okA) = _veHemiRow(i);
            (string memory b, bool okB) = _mirrorRow(i);
            if (!okA && !okB) break;
            if (!okA) {
                emit log_named_string("mirror has a member the proxy does not have", b);
                fail();
                return;
            }
            if (!okB) {
                emit log_named_string("mirror is missing a VeHemi state variable", a);
                fail();
                return;
            }
            if (!_eq(a, b)) {
                emit log_named_uint("member index", i);
                emit log_named_string("VeHemi  ", a);
                emit log_named_string("mirror  ", b);
                fail();
                return;
            }
            ++i;
            if (i > 256) revert("more than 256 storage entries");
        }
        assertGe(i, MIN_MEMBERS, "compared too few members to be meaningful");
    }

    // ──────────────────────────── LAYER B ───────────────────────────────────

    /// @notice After a real `enableAutoRelock`, R sits at the slot VeHemi's own
    ///         layout declares for `autoRelockRemaining`.
    ///
    ///         The expected slot comes from the committed layout, the observed
    ///         word from `vm.load` on the proxy. VeHemi, not a library, writes
    ///         R, so this pins VeHemi's layout, not the library mirror.
    function test_VeHemiWritesRAtTheDeclaredSlot() public {
        runSeedingFlow();
        (uint256 id,,) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        uint256 declared = _declaredSlot("autoRelockRemaining");
        assertEq(declared, 64, "V3 moved: autoRelockRemaining is no longer the slot-64 field");

        bytes32 raw = vm.load(address(veHemi), keccak256(abi.encode(id, declared)));
        emit log_named_uint("declared slot           ", declared);
        emit log_named_uint("value at declared slot  ", uint256(raw));
        emit log_named_uint("autoRelockRemaining()   ", veHemi.autoRelockRemaining(id));

        assertTrue(uint256(raw) != 0, "VeHemi stored R somewhere OTHER than the declared slot");
        assertEq(uint64(uint256(raw)), veHemi.autoRelockRemaining(id), "declared slot and getter disagree");
    }

    /// @notice The same, one slot either side: R must sit at neither
    ///         `keccak256(id . 63)` nor `keccak256(id . 65)`. Slot 65 is
    ///         `autoRelockRefreshedAt`, so its word for `id` holds the enable
    ///         stamp; the words at `keccak256(id . 63)` and
    ///         `keccak256(id . 66)` (slots 63 and 66 are gap words, not
    ///         mappings) hold nothing. Like the test above, this pins VeHemi's
    ///         own layout, not the mirror.
    function test_RLandsOnNeitherNeighbouringSlot() public {
        runSeedingFlow();
        (uint256 id,,) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        uint256 declared = _declaredSlot("autoRelockRemaining");
        assertEq(
            uint256(vm.load(address(veHemi), keccak256(abi.encode(id, declared - 1)))),
            0,
            "something wrote R one slot BELOW the declared mapping base"
        );
        // The next mapping base is `autoRelockRefreshedAt`: it must hold the
        // enable stamp (captured here, independently of any getter) and not R.
        uint256 stamp = block.timestamp; // no warp since enableAutoRelock
        uint256 above = uint256(vm.load(address(veHemi), keccak256(abi.encode(id, declared + 1))));
        assertEq(above, stamp, "slot 64+1 does not hold the enable stamp");
        assertTrue(above != uint256(veHemi.autoRelockRemaining(id)), "R found one slot ABOVE the declared base");
        assertEq(
            uint256(vm.load(address(veHemi), keccak256(abi.encode(id, declared + 2)))),
            0,
            "something wrote two slots ABOVE the declared mapping base"
        );
    }

    /// @dev The flat bias `VeHemiCurveLib.sol::checkpoint` books for an armed
    ///      position: `(amount / MAX_TIME) * (R - SIX_DAYS/2)`.
    function _flatBias(uint256 amount, uint256 r) internal pure returns (int128) {
        return (amount / MAX_TIME).toInt256().toInt128() * (r - SIX_DAYS / 2).toInt256().toInt128();
    }

    function _lastUserPoint(uint256 id) internal view returns (IVeHemi.Point memory) {
        return veHemi.getUserPoint(id, veHemi.userPointEpoch(id)).point;
    }

    /// @notice THE LIBRARY READ, which is what the mirror is for. The library
    ///         reads R through `VeHemiLayout`; VeHemi writes it through its own
    ///         layout. Plant a sentinel R at the slot VeHemi's committed layout
    ///         declares for `autoRelockRemaining` (VeHemi's getter must see it),
    ///         plant different sentinels one slot either side, and force a user
    ///         checkpoint with an owner `increaseAmount`: the flat bias must be
    ///         the one computed from the declared slot's sentinel. A one-word
    ///         mirror drift makes the library read a neighbour instead
    ///         (`[37]` -> `[38]` reads the `autoRelockRefreshedAt` word) and
    ///         fails here.
    function test_LibraryReadsRFromTheDeclaredSlot() public {
        runSeedingFlow();
        (uint256 id,,) = createLock(alice, 100 ether, 2 * 365 days);
        vm.prank(alice);
        veHemi.enableAutoRelock(id);

        uint256 declared = _declaredSlot("autoRelockRemaining");
        uint256 r = veHemi.autoRelockRemaining(id);
        assertGe(r, 2 * SIX_DAYS, "precondition: armed");

        // The enable itself: the library built the flat point from the R
        // VeHemi had just stored.
        IVeHemi.Point memory p = _lastUserPoint(id);
        assertEq(p.slope, 0, "enable did not book a flat point");
        assertEq(p.bias, _flatBias(100 ether, r), "enable: the library did not read R from the declared slot");

        // Sentinels: whole buckets, pairwise distinct, none equal to R or to
        // the stamp, all within MAX_TIME so every path stays in range.
        uint256 rDeclared = r - 2 * SIX_DAYS;
        uint256 rBelow = r - 4 * SIX_DAYS;
        uint256 rAbove = r - 6 * SIX_DAYS;
        vm.store(address(veHemi), keccak256(abi.encode(id, declared)), bytes32(rDeclared));
        vm.store(address(veHemi), keccak256(abi.encode(id, declared - 1)), bytes32(rBelow));
        vm.store(address(veHemi), keccak256(abi.encode(id, declared + 1)), bytes32(rAbove));
        assertEq(veHemi.autoRelockRemaining(id), rDeclared, "VeHemi's getter does not read the declared slot");

        // An owner `increaseAmount` checkpoints the id; nothing on that path
        // writes R.
        vm.startPrank(alice);
        hemi.mint(alice, 50 ether);
        veHemi.increaseAmount(id, 50 ether);
        vm.stopPrank();
        assertEq(veHemi.autoRelockRemaining(id), rDeclared, "increaseAmount rewrote R");

        p = _lastUserPoint(id);
        emit log_named_int("bias booked            ", p.bias);
        emit log_named_int("bias from declared slot", _flatBias(150 ether, rDeclared));
        emit log_named_int("bias from slot 64-1    ", _flatBias(150 ether, rBelow));
        emit log_named_int("bias from slot 64+1    ", _flatBias(150 ether, rAbove));
        assertEq(p.slope, 0, "increaseAmount did not book a flat point");
        assertEq(
            p.bias,
            _flatBias(150 ether, rDeclared),
            "the library read R from a slot OTHER than the declared one: MIRROR DRIFT"
        );
    }
}
