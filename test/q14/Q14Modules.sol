// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "../k08/K08Modules.sol";

/// @title  A module that answers every `delegate` with
///         `DelegationSlopeOverflow()` (`0xf2b4513c`), the one selector VeHemi
///         re-raises on the holder's `disableAutoRelock` leg.
///
/// @dev    The real module raises this selector only when a delegatee's
///         aggregate slope would overflow `uint64`. This mock is the
///         ADVERSARIAL shape: a broken module that CHOOSES the selector, so the
///         tests can check that the holder still has an owner-independent way
///         out (the strict re-raise and armed-transfer suites).
///         `disarm()` makes `delegate` accept again.
contract Q14SlopeOverflowLiar is K08ModuleBase {
    error DelegationSlopeOverflow();
    mapping(uint256 => Delegation) internal recs;
    bool public armed = true;

    function seed(uint256 id_, address delegatee_, uint96 bias_, uint64 slope_) external {
        recs[id_] = Delegation({
            delegatee: delegatee_,
            end: uint48(block.timestamp + 365 days),
            bias: bias_,
            amount: 0,
            slope: slope_
        });
    }

    function disarm() external { armed = false; }

    function delegate(uint256, address) external view override {
        if (armed) revert DelegationSlopeOverflow();
    }

    function delegation(uint256 id_) external view override returns (Delegation memory) {
        return recs[id_];
    }
}
