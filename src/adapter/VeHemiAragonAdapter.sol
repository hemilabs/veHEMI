// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @dev Minimal interface for VeHemi queries used by the adapter.
interface IVeHemiAdapter {
    struct LockedBalance {
        int128 amount;
        uint64 end;
    }

    function balanceOf(address account) external view returns (uint256);
    function totalVeHemiSupply() external view returns (uint256);
    function voteDelegation() external view returns (address);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function getLockedBalance(uint256 tokenId) external view returns (LockedBalance memory);
}

/// @dev Minimal interface for VeHemiVoteDelegation functions used by the adapter.
interface IVoteDelegation {
    struct Delegation {
        address delegatee;
        uint48 end;
        uint96 bias;
        uint96 amount;
        uint64 slope;
    }

    function getVotes(address account) external view returns (uint256);
    function getPastVotes(address account, uint256 timestamp) external view returns (uint256);
    function getPastTotalSupply(uint256 timestamp) external view returns (uint256);
    function clock() external view returns (uint48);
    function CLOCK_MODE() external view returns (string memory);
    function delegation(uint256 tokenId) external view returns (Delegation memory);
    function delegateAllFor(address owner, address delegatee) external;
    function refreshVotingPower(address delegatee) external;
    function refreshVotingPowerBatch(address[] calldata delegatees) external;
}

/// @dev IVotes interface for ERC-165 interfaceId computation.
///      Matches Aragon's IVotesUpgradeable at the ABI level.
interface IVotes {
    function getVotes(address account) external view returns (uint256);
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
    function delegates(address account) external view returns (address);
    function delegate(address delegatee) external;
    function delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) external;
}

/// @title VeHemiAragonAdapter
/// @notice Stateless, immutable adapter that presents veHEMI voting power through
///         the IVotes + ERC20 interface expected by Aragon's TokenVoting plugin.
/// @dev All calls are forwarded to the underlying VeHemi and its VeHemiVoteDelegation
///      contracts. The voteDelegation address is read dynamically from VeHemi storage,
///      so governance automatically follows any future VeHemi.updateVoteDelegation() calls.
///
///      delegate(address) calls delegateAllFor on the delegation contract, which
///      delegates ALL of the caller's veHEMI positions to the specified delegatee.
///      This requires the adapter to be set as trustedAdapter on VeHemiVoteDelegation.
///
///      delegates(address) returns the delegatee address ONLY if all of the account's
///      veHEMI positions are delegated to the same address. Returns address(0) if the
///      account has no positions or if positions are split across different delegatees.
contract VeHemiAragonAdapter {
    IVeHemiAdapter private immutable _veHemi;

    constructor(address veHemi_) {
        require(veHemi_ != address(0), "zero veHemi");
        _veHemi = IVeHemiAdapter(veHemi_);
    }

    /// @dev Reads the current voteDelegation contract from VeHemi storage.
    function _delegation() private view returns (IVoteDelegation) {
        return IVoteDelegation(_veHemi.voteDelegation());
    }

    // --- Immutable references ---

    function veHemi() external view returns (address) {
        return address(_veHemi);
    }

    function voteDelegation() external view returns (address) {
        return address(_delegation());
    }

    // --- ERC20-like (for Aragon frontend & isMember) ---

    /// @notice Returns the total locked HEMI across all of an account's veHEMI positions.
    /// @dev Iterates the account's NFTs and sums locked amounts. This provides a
    ///      meaningful "token balance" for the Aragon member detail page rather than
    ///      the raw NFT position count.
    ///
    ///      ASYMMETRY WITH `totalSupply()`: `balanceOf(account)` returns the raw locked
    ///      HEMI amount, while `totalSupply()` returns aggregate decayed stake weight.
    ///      The two are deliberately different quantities — `balanceOf` is a stable,
    ///      user-recognizable "how much HEMI did I lock" number (matches the member
    ///      detail page's expectation), while `totalSupply` matches the value space of
    ///      `getVotes` / `getPastVotes` so Aragon's voting-threshold arithmetic is
    ///      consistent with delegated voting power. They will NOT sum to a single
    ///      meaningful total; do not compare them directly.
    function balanceOf(address account) external view returns (uint256 total) {
        uint256 count = _veHemi.balanceOf(account);
        for (uint256 i; i < count;) {
            uint256 tokenId = _veHemi.tokenOfOwnerByIndex(account, i);
            int128 amount = _veHemi.getLockedBalance(tokenId).amount;
            if (amount > 0) total += uint128(amount);
            unchecked { ++i; }
        }
    }

    /// @notice Fixed at 18 to match HEMI's ERC20 decimals.
    /// @dev Aragon's TokenVoting UI reads `decimals()` to render voting-power values.
    ///      HEMI is an 18-decimal ERC20; the `balanceOf` sum above and `totalVeHemiSupply`
    ///      are both denominated in 18-decimal wei. Hardcoded rather than proxied through
    ///      VeHemi so this view is pure and cannot revert.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Returns the global aggregate stake weight (decayed voting power) across
    ///         all veHEMI positions. This matches the value space of `getVotes` /
    ///         `getPastVotes`, so Aragon's quorum/support threshold arithmetic stays
    ///         consistent with the sum of all delegate voting powers.
    /// @dev See the `balanceOf` NatSpec for the rationale behind the intentional
    ///      asymmetry between `balanceOf` (locked HEMI) and `totalSupply` (stake weight).
    function totalSupply() external view returns (uint256) {
        return _veHemi.totalVeHemiSupply();
    }

    // --- IVotes ---

    function getVotes(address account) external view returns (uint256) {
        return _delegation().getVotes(account);
    }

    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        return _delegation().getPastVotes(account, timepoint);
    }

    function getPastTotalSupply(uint256 timepoint) external view returns (uint256) {
        return _delegation().getPastTotalSupply(timepoint);
    }

    /// @notice Returns the delegatee if ALL of the account's veHEMI positions are
    ///         delegated to the same address. Returns address(0) if positions are
    ///         split across different delegatees or the account has no positions.
    function delegates(address account) external view returns (address) {
        uint256 count = _veHemi.balanceOf(account);
        if (count == 0) return address(0);

        IVoteDelegation d = _delegation();
        uint256 firstTokenId = _veHemi.tokenOfOwnerByIndex(account, 0);
        address firstDelegatee = d.delegation(firstTokenId).delegatee;

        for (uint256 i = 1; i < count;) {
            uint256 tokenId = _veHemi.tokenOfOwnerByIndex(account, i);
            if (d.delegation(tokenId).delegatee != firstDelegatee) {
                return address(0);
            }
            unchecked { ++i; }
        }

        return firstDelegatee;
    }

    /// @notice Delegates ALL of the caller's veHEMI positions to the specified delegatee.
    ///         Requires this adapter to be set as trustedAdapter on VeHemiVoteDelegation.
    function delegate(address delegatee) external {
        _delegation().delegateAllFor(msg.sender, delegatee);
    }

    /// @notice Always reverts. Use `VeHemiVoteDelegation.delegateBySig` directly.
    /// @dev The standard IVotes `delegateBySig(address delegatee, uint256 nonce, ...)`
    ///      signs over an account-wide delegatee. veHEMI's native delegation is per-tokenId,
    ///      so there is no transparent way to forward this signature — a naive "delegate
    ///      all my positions" translation would produce a different digest than the one
    ///      the user signed, which is unsafe. Signers must instead use
    ///      `VeHemiVoteDelegation.delegateBySig(tokenId, delegatee, ...)` whose EIP-712
    ///      typehash explicitly includes the tokenId.
    ///
    ///      The function is still declared (reverting) so `supportsInterface(IVotes)` is
    ///      truthful at the ABI level — Aragon's ERC-165 probe sees the full IVotes
    ///      surface — while at runtime the unsupported signature path produces an
    ///      unambiguous revert string rather than silent misbehavior.
    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure {
        revert("Use VeHemiVoteDelegation.delegateBySig");
    }

    // --- Event relay (for Aragon subgraph indexing) ---

    /// @dev Relayed from VeHemiVoteDelegation so events are emitted from
    ///      the adapter address, which is what Aragon's subgraph indexes.
    event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

    /// @dev Standard IVotes DelegateChanged (address-based, not tokenId-based).
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    /// @notice Called by VeHemiVoteDelegation to relay DelegateVotesChanged events
    ///         from the adapter address for Aragon subgraph compatibility.
    function notifyVotesChanged(address delegatee, uint256 previousVotes, uint256 newVotes) external {
        require(msg.sender == address(_delegation()), "unauthorized");
        emit DelegateVotesChanged(delegatee, previousVotes, newVotes);
    }

    /// @notice Called by VeHemiVoteDelegation to relay DelegateChanged events
    ///         with the standard IVotes signature (address delegator, not uint256 tokenId).
    function notifyDelegateChanged(address delegator, address fromDelegate, address toDelegate) external {
        require(msg.sender == address(_delegation()), "unauthorized");
        emit DelegateChanged(delegator, fromDelegate, toDelegate);
    }

    // --- Voting power refresh (permissionless) ---

    /// @notice Re-emits a DelegateVotesChanged event with the current on-chain voting
    ///         power for `delegatee`. This forces the Aragon subgraph to re-sync its
    ///         cached votingPower value without any actual delegation change.
    /// @dev    Delegates to VeHemiVoteDelegation.refreshVotingPower which uses the
    ///         next-epoch-boundary checkpoint timestamp (consistent with delegation
    ///         events) and relays the event back to this adapter via notifyVotesChanged.
    ///         This avoids the timestamp mismatch that occurs when using getVotes()
    ///         (which uses block.timestamp) directly.
    ///
    ///         Permissionless by design: any address can call this to nudge the subgraph.
    ///         The function does not mutate delegation state — it only re-emits an event
    ///         with values that are already readable on-chain. A griefer who spammed
    ///         `refreshVotingPower` for random addresses would pay gas to emit redundant
    ///         events that the subgraph would fold into identical already-stored values;
    ///         no griefing surface on the core contract (beyond ordinary event spam,
    ///         which the subgraph is built to absorb). The intended caller is an off-chain
    ///         keeper that periodically walks the active delegate set to keep voting
    ///         power displays in sync with linear decay.
    function refreshVotingPower(address delegatee) external {
        _delegation().refreshVotingPower(delegatee);
    }

    /// @notice Batch version of refreshVotingPower for multiple delegatees in a
    ///         single transaction.
    /// @dev    Delegates to VeHemiVoteDelegation.refreshVotingPowerBatch for
    ///         timestamp-consistent event emission. Same permissionless-by-design
    ///         rationale as `refreshVotingPower`; caller pays gas linear in array length.
    function refreshVotingPowerBatch(address[] calldata delegatees) external {
        _delegation().refreshVotingPowerBatch(delegatees);
    }

    // --- ERC-6372 ---

    function clock() external view returns (uint48) {
        return _delegation().clock();
    }

    function CLOCK_MODE() external view returns (string memory) {
        return _delegation().CLOCK_MODE();
    }

    // --- ERC-165 ---

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IVotes).interfaceId
            || interfaceId == 0x01ffc9a7  // ERC-165
            || interfaceId == 0xda287a1d; // IERC6372 (clock() ^ CLOCK_MODE())
    }

    // --- Metadata ---

    function name() external pure returns (string memory) {
        return "veHEMI Votes";
    }

    function symbol() external pure returns (string memory) {
        return "veHEMI";
    }
}
