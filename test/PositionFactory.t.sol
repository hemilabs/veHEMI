// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/utils/PositionFactory.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHemiVoteDelegation.sol";

contract PositionFactoryTest is Test {
    PositionFactory factory;
    VeHemi veHemi;
    MockERC20 hemi;
    MockHemiVoteDelegation mockDelegation;

    address owner = address(this);
    address alice = address(0x1122);
    address bob = address(0x3344);
    address sponsor = address(0x5566);

    uint256 private constant YEAR = 365.25 days;

    uint256 constant AMOUNT = 100 ether;
    uint256 constant DURATION = 2 * YEAR;

    function setUp() public {
        hemi = new MockERC20("HEMI", "HEMI", 18);

        // Deploy VeHemi behind a proxy (same pattern as VeHemiTest)
        VeHemi logic = new VeHemi(address(hemi));
        mockDelegation = new MockHemiVoteDelegation();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, owner)
        );
        veHemi = VeHemi(address(proxy));
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(mockDelegation)));

        // Deploy the factory pointing at the live VeHemi
        factory = new PositionFactory(address(veHemi), owner);

        // Fund and approve
        hemi.mint(sponsor, 10_000 ether);
        vm.prank(sponsor);
        hemi.approve(address(factory), type(uint256).max);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(address(factory.veHemi()), address(veHemi));
        assertEq(address(factory.hemi()), address(hemi));
        assertEq(factory.owner(), owner);
    }

    function test_constructor_revertsOnZeroVeHemi() public {
        vm.expectRevert(PositionFactory.InvalidVeHemi.selector);
        new PositionFactory(address(0), owner);
    }

    function test_constructor_derivesHemiFromVeHemi() public view {
        // hemi should be derived from veHemi.HEMI(), not passed separately
        assertEq(address(factory.hemi()), address(veHemi.HEMI()));
    }

    // =========================================================================
    // updateStatus
    // =========================================================================

    function test_updateStatus_setsPending() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        bool[] memory transferables = new bool[](1);
        bool[] memory forfeitables = new bool[](1);
        users[0] = alice;
        amounts[0] = AMOUNT;
        durations[0] = DURATION;
        transferables[0] = true;
        forfeitables[0] = false;

        bytes32 expectedHash = keccak256(abi.encodePacked(alice, AMOUNT, DURATION, true, false));

        vm.expectEmit(true, true, false, true);
        emit PositionFactory.StatusUpdated(
            expectedHash, alice, AMOUNT, DURATION, true, false, PositionFactory.Status.PENDING
        );

        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.PENDING, false
        );

        assertEq(uint256(factory.created(expectedHash)), uint256(PositionFactory.Status.PENDING));
    }

    function test_updateStatus_revertsForNonOwner() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        bool[] memory transferables = new bool[](1);
        bool[] memory forfeitables = new bool[](1);
        users[0] = alice;
        amounts[0] = AMOUNT;
        durations[0] = DURATION;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.PENDING, false
        );
    }

    function test_updateStatus_revertsOnArrayLengthMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        bool[] memory transferables = new bool[](1);
        bool[] memory forfeitables = new bool[](1);

        vm.expectRevert(PositionFactory.InvalidArrays.selector);
        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.PENDING, false
        );
    }

    function test_updateStatus_revertsOnDurationLengthMismatch() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory durations = new uint256[](2);
        bool[] memory transferables = new bool[](1);
        bool[] memory forfeitables = new bool[](1);

        vm.expectRevert(PositionFactory.InvalidArrays.selector);
        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.PENDING, false
        );
    }

    function test_updateStatus_revertsOnTransferableLengthMismatch() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        bool[] memory transferables = new bool[](2);
        bool[] memory forfeitables = new bool[](1);

        vm.expectRevert(PositionFactory.InvalidArrays.selector);
        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.PENDING, false
        );
    }

    function test_updateStatus_revertsOnForfeitableLengthMismatch() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        bool[] memory transferables = new bool[](1);
        bool[] memory forfeitables = new bool[](2);

        vm.expectRevert(PositionFactory.InvalidArrays.selector);
        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.PENDING, false
        );
    }

    function test_updateStatus_revertIfCreated_true() public {
        // Whitelist and create a position first
        _whitelistAndCreate(alice, AMOUNT, DURATION, true, false);

        // Try to overwrite with revertIfCreated_=true
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        bool[] memory transferables = new bool[](1);
        bool[] memory forfeitables = new bool[](1);
        users[0] = alice;
        amounts[0] = AMOUNT;
        durations[0] = DURATION;
        transferables[0] = true;
        forfeitables[0] = false;

        vm.expectRevert(abi.encodeWithSelector(
            PositionFactory.PositionCreatedAlready.selector, alice, AMOUNT, DURATION
        ));
        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.PENDING, true
        );
    }

    function test_updateStatus_revertIfCreated_false_overwritesSilently() public {
        _whitelistAndCreate(alice, AMOUNT, DURATION, true, false);

        bytes32 hash = keccak256(abi.encodePacked(alice, AMOUNT, DURATION, true, false));
        assertEq(uint256(factory.created(hash)), uint256(PositionFactory.Status.CREATED));

        // Overwrite with revertIfCreated_=false — succeeds
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        bool[] memory transferables = new bool[](1);
        bool[] memory forfeitables = new bool[](1);
        users[0] = alice;
        amounts[0] = AMOUNT;
        durations[0] = DURATION;
        transferables[0] = true;
        forfeitables[0] = false;

        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.NONE, false
        );

        assertEq(uint256(factory.created(hash)), uint256(PositionFactory.Status.NONE));
    }

    function test_updateStatus_batchMultipleUsers() public {
        address[] memory users = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        uint256[] memory durations = new uint256[](3);
        bool[] memory transferables = new bool[](3);
        bool[] memory forfeitables = new bool[](3);
        users[0] = alice;     amounts[0] = 10 ether;  durations[0] = DURATION;
        users[1] = bob;       amounts[1] = 20 ether;  durations[1] = DURATION;
        users[2] = sponsor;   amounts[2] = 30 ether;  durations[2] = DURATION;
        // mixed flag profiles to exercise hash-binding
        transferables[0] = true;  forfeitables[0] = false;
        transferables[1] = false; forfeitables[1] = true;
        transferables[2] = false; forfeitables[2] = false;

        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.PENDING, false
        );

        for (uint256 i; i < 3; ++i) {
            bytes32 hash = keccak256(
                abi.encodePacked(users[i], amounts[i], durations[i], transferables[i], forfeitables[i])
            );
            assertEq(uint256(factory.created(hash)), uint256(PositionFactory.Status.PENDING));
        }
    }

    // Flag-binding: a caller supplying flags that differ from what the owner
    // whitelisted must hash to a different (unwhitelisted) slot and revert.
    function test_create_rejectsSpoofedTransferableFlag() public {
        // Owner whitelists a NON-transferable, FORFEITABLE position for alice.
        _whitelist(alice, AMOUNT, DURATION, false, true);

        // Attacker tries to mint as transferable (or any other flag combo) → reverts
        // because the spoofed hash hits Status.NONE.
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(
            PositionFactory.PositionCreatedAlready.selector, alice, AMOUNT, DURATION
        ));
        factory.create(alice, AMOUNT, DURATION, true, false);

        // The legitimate flag combo still works.
        vm.prank(sponsor);
        factory.create(alice, AMOUNT, DURATION, false, true);
        assertFalse(veHemi.isTransferable(1));
        assertTrue(veHemi.forfeitable(1));
    }

    function test_create_rejectsSpoofedForfeitableFlag() public {
        _whitelist(alice, AMOUNT, DURATION, true, false);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(
            PositionFactory.PositionCreatedAlready.selector, alice, AMOUNT, DURATION
        ));
        factory.create(alice, AMOUNT, DURATION, true, true);
    }

    // =========================================================================
    // create
    // =========================================================================

    function test_create_happyPath() public {
        _whitelist(alice, AMOUNT, DURATION, true, false);

        bytes32 expectedHash = keccak256(abi.encodePacked(alice, AMOUNT, DURATION, true, false));

        vm.expectEmit(true, true, false, true);
        emit PositionFactory.PositionCreated(expectedHash, alice, AMOUNT, DURATION, true, false);

        uint256 sponsorBalBefore = hemi.balanceOf(sponsor);

        vm.prank(sponsor);
        factory.create(alice, AMOUNT, DURATION, true, false);

        // Status is CREATED
        assertEq(uint256(factory.created(expectedHash)), uint256(PositionFactory.Status.CREATED));

        // Sponsor paid the HEMI
        assertEq(hemi.balanceOf(sponsor), sponsorBalBefore - AMOUNT);

        // Factory holds no residual HEMI or approval
        assertEq(hemi.balanceOf(address(factory)), 0);
        assertEq(hemi.allowance(address(factory), address(veHemi)), 0);

        // VeHemi minted a position owned by alice
        uint256 tokenId = 1;
        assertEq(veHemi.ownerOf(tokenId), alice);

        // Lock amount matches
        IVeHemi.LockedBalance memory bal = veHemi.getLockedBalance(tokenId);
        assertEq(uint256(uint128(bal.amount)), AMOUNT);

        // VeHemi's totalLocked increased
        assertEq(veHemi.totalLocked(), AMOUNT);
    }

    function test_create_revertsWhenStatusNone() public {
        // No prior updateStatus — hash defaults to NONE
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(
            PositionFactory.PositionCreatedAlready.selector, alice, AMOUNT, DURATION
        ));
        factory.create(alice, AMOUNT, DURATION, true, false);
    }

    function test_create_revertsWhenAlreadyCreated() public {
        _whitelistAndCreate(alice, AMOUNT, DURATION, true, false);

        // Second create with same args reverts
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(
            PositionFactory.PositionCreatedAlready.selector, alice, AMOUNT, DURATION
        ));
        factory.create(alice, AMOUNT, DURATION, true, false);
    }

    function test_create_hashIsSensitiveToArgs() public {
        // Whitelist for (alice, 100e18, DURATION, true, false)
        _whitelist(alice, AMOUNT, DURATION, true, false);

        // Calling with amount+1 should revert — different hash, status is NONE
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(
            PositionFactory.PositionCreatedAlready.selector, alice, AMOUNT + 1, DURATION
        ));
        factory.create(alice, AMOUNT + 1, DURATION, true, false);
    }

    function test_create_nonTransferableForfeitable() public {
        _whitelist(alice, AMOUNT, DURATION, false, true);

        vm.prank(sponsor);
        factory.create(alice, AMOUNT, DURATION, false, true);

        uint256 tokenId = 1;
        assertEq(veHemi.ownerOf(tokenId), alice);
        assertFalse(veHemi.isTransferable(tokenId));
        assertTrue(veHemi.forfeitable(tokenId));
    }

    function test_create_providerIsFactory() public {
        _whitelist(alice, AMOUNT, DURATION, true, false);

        vm.prank(sponsor);
        factory.create(alice, AMOUNT, DURATION, true, false);

        uint256 tokenId = 1;
        // The factory is the immediate caller of createLockFor, so provider == factory.
        // (Not the sponsor — the factory is the msg.sender to veHemi.)
        assertEq(veHemi.provider(tokenId), address(factory));
    }

    function test_create_revertsOnTransferableAndForfeitable() public {
        // Whitelist matching the (true, true) combo we are about to call create with.
        _whitelist(alice, AMOUNT, DURATION, true, true);

        // VeHemi rejects positions that are both transferable and forfeitable
        vm.prank(sponsor);
        vm.expectRevert(VeHemi.InvalidConfiguration.selector);
        factory.create(alice, AMOUNT, DURATION, true, true);

        // Status should have been set to CREATED (CEI: effects before interactions),
        // so the revert from VeHemi doesn't leave a stale PENDING entry — it rolls
        // back the entire transaction including the status update.
        bytes32 hash = keccak256(abi.encodePacked(alice, AMOUNT, DURATION, true, true));
        assertEq(uint256(factory.created(hash)), uint256(PositionFactory.Status.PENDING),
            "Status should remain PENDING after reverted create");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _whitelist(
        address user_,
        uint256 amount_,
        uint256 duration_,
        bool transferable_,
        bool forfeitable_
    ) internal {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        bool[] memory transferables = new bool[](1);
        bool[] memory forfeitables = new bool[](1);
        users[0] = user_;
        amounts[0] = amount_;
        durations[0] = duration_;
        transferables[0] = transferable_;
        forfeitables[0] = forfeitable_;
        factory.updateStatus(
            users, amounts, durations, transferables, forfeitables,
            PositionFactory.Status.PENDING, false
        );
    }

    function _whitelistAndCreate(
        address user_,
        uint256 amount_,
        uint256 duration_,
        bool transferable_,
        bool forfeitable_
    ) internal {
        _whitelist(user_, amount_, duration_, transferable_, forfeitable_);
        vm.prank(sponsor);
        factory.create(user_, amount_, duration_, transferable_, forfeitable_);
    }
}
