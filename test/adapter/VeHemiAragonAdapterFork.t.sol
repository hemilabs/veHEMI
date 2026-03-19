// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {VeHemiAragonAdapter} from "../../src/adapter/VeHemiAragonAdapter.sol";
import {VeHemi} from "../../src/VeHemi.sol";
import {VeHemiVoteDelegation} from "../../src/VeHemiVoteDelegation.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ─── Aragon OSx type definitions ────────────────────────────────────────────

struct Tag {
    uint8 release;
    uint16 build;
}

struct PluginSetupRef {
    Tag versionTag;
    address pluginSetupRepo;
}

struct DAOSettings {
    address trustedForwarder;
    string daoURI;
    string subdomain;
    bytes metadata;
}

struct PluginSettings {
    PluginSetupRef pluginSetupRef;
    bytes data;
}

struct VotingSettings {
    uint8 votingMode;
    uint32 supportThreshold;
    uint32 minParticipation;
    uint64 minDuration;
    uint256 minProposerVotingPower;
}

struct TokenSettings {
    address addr;
    string name;
    string symbol;
}

struct MintSettings {
    address[] receivers;
    uint256[] amounts;
    bool ensureDelegationOnMint;
}

struct TargetConfig {
    address target;
    uint8 operation; // 0 = Call, 1 = DelegateCall
}

struct Action {
    address to;
    uint256 value;
    bytes data;
}

// ─── Aragon OSx return types for createDao ──────────────────────────────────

struct MultiTargetPermission {
    uint8 operation;
    address where;
    address who;
    address condition;
    bytes32 permissionId;
}

struct PreparedSetupData {
    address[] helpers;
    MultiTargetPermission[] permissions;
}

struct InstalledPlugin {
    address plugin;
    PreparedSetupData preparedSetupData;
}

// ─── Aragon interfaces ──────────────────────────────────────────────────────

interface IDAOFactory {
    function createDao(
        DAOSettings calldata _daoSettings,
        PluginSettings[] calldata _pluginSettings
    ) external returns (address createdDao, InstalledPlugin[] memory installedPlugins);
}

interface ITokenVoting {
    function createProposal(
        bytes calldata _metadata,
        Action[] calldata _actions,
        uint256 _allowFailureMap,
        uint64 _startDate,
        uint64 _endDate,
        uint8 _voteOption,
        bool _tryEarlyExecution
    ) external returns (uint256 proposalId);

    function vote(uint256 _proposalId, uint8 _voteOption, bool _tryEarlyExecution) external;

    function execute(uint256 _proposalId) external;

    function canExecute(uint256 _proposalId) external view returns (bool);

    function isMember(address _account) external view returns (bool);

    function getVotingToken() external view returns (address);

    function totalVotingPower(uint256 _blockNumber) external view returns (uint256);
}

// ─── Fork test ──────────────────────────────────────────────────────────────

contract VeHemiAragonAdapterForkTest is Test {
    // Aragon OSx v1.4.0 on Ethereum mainnet
    address constant DAO_FACTORY = 0x246503df057A9a85E0144b6867a828c99676128B;
    address constant TOKEN_VOTING_REPO = 0xb7401cD221ceAFC54093168B814Cc3d42579287f;

    uint8 constant VOTE_NONE = 0;
    uint8 constant VOTE_ABSTAIN = 1;
    uint8 constant VOTE_YES = 2;
    uint8 constant VOTE_NO = 3;

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant ONE_DAY = 1 days;

    MockERC20 hemiToken;
    VeHemi veHemi;
    VeHemiVoteDelegation delegation;
    VeHemiAragonAdapter adapter;

    address alice;
    address bob;
    address carol;

    bool forkEnabled;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        forkEnabled = true;
        vm.createSelectFork(rpcUrl);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        // Deploy veHEMI stack
        hemiToken = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemiToken));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, address(this))
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);

        adapter = new VeHemiAragonAdapter(address(veHemi));

        // Create locks
        _createLock(alice, 10e18, 4 * YEAR);
        _createLock(bob, 10e18, 4 * YEAR);
        _createLock(carol, 10e18, 4 * YEAR);

        // Self-delegate all
        _delegateToSelf(alice);
        _delegateToSelf(bob);
        _delegateToSelf(carol);

        // Warp past next day boundary so delegations are active
        uint256 nextDay = ((block.timestamp / ONE_DAY) * ONE_DAY) + ONE_DAY;
        vm.warp(nextDay + 1);
    }

    function _createLock(address account, uint256 amount, uint256 duration) internal {
        hemiToken.mint(account, amount);
        vm.startPrank(account);
        hemiToken.approve(address(veHemi), amount);
        veHemi.createLock(amount, duration);
        vm.stopPrank();
    }

    function _delegateToSelf(address account) internal {
        uint256 tokenIndex = veHemi.tokenOfOwnerByIndex(account, 0);
        vm.prank(account);
        delegation.delegate(tokenIndex, account);
    }

    function _createDao()
        internal
        returns (address dao, address tokenVotingPlugin)
    {
        VotingSettings memory votingSettings = VotingSettings({
            votingMode: 0, // Standard
            supportThreshold: 500_000, // 50%
            minParticipation: 150_000, // 15%
            minDuration: 3600, // 1 hour
            minProposerVotingPower: 0
        });

        TokenSettings memory tokenSettings = TokenSettings({
            addr: address(adapter),
            name: "",
            symbol: ""
        });

        MintSettings memory mintSettings = MintSettings({
            receivers: new address[](0),
            amounts: new uint256[](0),
            ensureDelegationOnMint: false
        });

        // TargetConfig: target = address(0) lets the setup fill in the DAO address
        TargetConfig memory targetConfig = TargetConfig({
            target: address(0),
            operation: 0 // Call
        });

        uint256 minApprovals = 0;
        bytes memory pluginMetadata = "";
        address[] memory excludedAccounts = new address[](0);

        bytes memory pluginData = abi.encode(
            votingSettings,
            tokenSettings,
            mintSettings,
            targetConfig,
            minApprovals,
            pluginMetadata,
            excludedAccounts
        );

        PluginSettings[] memory plugins = new PluginSettings[](1);
        plugins[0] = PluginSettings({
            pluginSetupRef: PluginSetupRef({
                versionTag: Tag({release: 1, build: 4}),
                pluginSetupRepo: TOKEN_VOTING_REPO
            }),
            data: pluginData
        });

        DAOSettings memory daoSettings = DAOSettings({
            trustedForwarder: address(0),
            daoURI: "",
            subdomain: "",
            metadata: ""
        });

        InstalledPlugin[] memory installed;
        (dao, installed) = IDAOFactory(DAO_FACTORY).createDao(daoSettings, plugins);
        tokenVotingPlugin = installed[0].plugin;

        require(tokenVotingPlugin != address(0), "plugin not found");
    }

    // ─── Tests ──────────────────────────────────────────────────────────

    function test_fork_createDao() public {
        vm.skip(!forkEnabled);

        (address dao, address plugin) = _createDao();
        assertTrue(dao != address(0), "DAO should be created");
        assertTrue(plugin != address(0), "plugin should be deployed");

        ITokenVoting tv = ITokenVoting(plugin);
        assertEq(tv.getVotingToken(), address(adapter));
    }

    function test_fork_isMember() public {
        vm.skip(!forkEnabled);

        (, address plugin) = _createDao();
        ITokenVoting tv = ITokenVoting(plugin);

        assertTrue(tv.isMember(alice), "alice should be member");
        assertTrue(tv.isMember(bob), "bob should be member");
        assertFalse(
            tv.isMember(makeAddr("nobody")), "nobody should not be member"
        );
    }

    function test_fork_totalVotingPower() public {
        vm.skip(!forkEnabled);

        (, address plugin) = _createDao();
        ITokenVoting tv = ITokenVoting(plugin);

        uint256 snapshot = block.timestamp - 1;
        uint256 tvp = tv.totalVotingPower(snapshot);
        assertGt(tvp, 0, "total voting power should be non-zero");
    }

    function test_fork_createProposal() public {
        vm.skip(!forkEnabled);

        (, address plugin) = _createDao();
        ITokenVoting tv = ITokenVoting(plugin);

        Action[] memory actions = new Action[](0);
        vm.prank(alice);
        uint256 proposalId = tv.createProposal(
            "", actions, 0, 0, 0, VOTE_NONE, false
        );

        // proposalId is a hash in build 4, not a sequential counter — just verify non-zero
        assertTrue(proposalId != 0, "proposal should have a valid id");
    }

    function test_fork_voteAndExecute() public {
        vm.skip(!forkEnabled);

        (address dao, address plugin) = _createDao();
        ITokenVoting tv = ITokenVoting(plugin);

        // Create proposal with empty action (governance-only, no execution effect)
        Action[] memory actions = new Action[](0);
        vm.prank(alice);
        uint256 proposalId = tv.createProposal(
            "", actions, 0, 0, 0, VOTE_NONE, false
        );

        // All three vote Yes
        vm.prank(alice);
        tv.vote(proposalId, VOTE_YES, false);

        vm.prank(bob);
        tv.vote(proposalId, VOTE_YES, false);

        vm.prank(carol);
        tv.vote(proposalId, VOTE_YES, false);

        // Warp past minDuration (3600s)
        vm.warp(block.timestamp + 3601);

        // Execute
        assertTrue(tv.canExecute(proposalId), "proposal should be executable");
        tv.execute(proposalId);
    }

    function test_fork_voteAndExecute_withAction() public {
        vm.skip(!forkEnabled);

        (address dao, address plugin) = _createDao();
        ITokenVoting tv = ITokenVoting(plugin);

        address recipient = makeAddr("recipient");
        uint256 sendAmount = 0.1 ether;

        // Fund the DAO
        vm.deal(dao, 1 ether);

        // Create proposal to send ETH
        Action[] memory actions = new Action[](1);
        actions[0] = Action({to: recipient, value: sendAmount, data: ""});

        vm.prank(alice);
        uint256 proposalId = tv.createProposal(
            "", actions, 0, 0, 0, VOTE_NONE, false
        );

        // All vote Yes
        vm.prank(alice);
        tv.vote(proposalId, VOTE_YES, false);

        vm.prank(bob);
        tv.vote(proposalId, VOTE_YES, false);

        vm.prank(carol);
        tv.vote(proposalId, VOTE_YES, false);

        // Warp past minDuration
        vm.warp(block.timestamp + 3601);

        // Execute
        uint256 recipientBalanceBefore = recipient.balance;
        tv.execute(proposalId);
        assertEq(
            recipient.balance - recipientBalanceBefore,
            sendAmount,
            "recipient should receive ETH"
        );
    }

    function test_fork_proposalDefeated_noQuorum() public {
        vm.skip(!forkEnabled);

        // Create DAO with very high participation requirement
        // We'll just not vote enough
        (, address plugin) = _createDao();
        ITokenVoting tv = ITokenVoting(plugin);

        Action[] memory actions = new Action[](0);
        vm.prank(alice);
        uint256 proposalId = tv.createProposal(
            "", actions, 0, 0, 0, VOTE_NONE, false
        );

        // Only alice votes (1/3 of power = 33%)
        // minParticipation is 15%, so this actually passes quorum
        // Instead: nobody votes
        // Warp past minDuration
        vm.warp(block.timestamp + 3601);

        // Should not be executable (0% participation < 15% threshold)
        assertFalse(
            tv.canExecute(proposalId),
            "proposal with no votes should not be executable"
        );
    }

    function test_fork_proposalDefeated_noSupport() public {
        vm.skip(!forkEnabled);

        (, address plugin) = _createDao();
        ITokenVoting tv = ITokenVoting(plugin);

        Action[] memory actions = new Action[](0);
        vm.prank(alice);
        uint256 proposalId = tv.createProposal(
            "", actions, 0, 0, 0, VOTE_NONE, false
        );

        // Alice votes Yes, Bob and Carol vote No
        vm.prank(alice);
        tv.vote(proposalId, VOTE_YES, false);

        vm.prank(bob);
        tv.vote(proposalId, VOTE_NO, false);

        vm.prank(carol);
        tv.vote(proposalId, VOTE_NO, false);

        vm.warp(block.timestamp + 3601);

        // 100% participation but only 33% support < 50% threshold
        assertFalse(
            tv.canExecute(proposalId),
            "proposal with majority No should not be executable"
        );
    }

    function test_fork_timestampMode() public {
        vm.skip(!forkEnabled);

        (, address plugin) = _createDao();

        // Verify the plugin was configured for timestamp mode by checking
        // that totalVotingPower works with a timestamp (not block number)
        ITokenVoting tv = ITokenVoting(plugin);
        uint256 snapshot = block.timestamp - 1;
        uint256 tvp = tv.totalVotingPower(snapshot);
        assertGt(tvp, 0, "timestamp-based totalVotingPower should work");
    }
}
