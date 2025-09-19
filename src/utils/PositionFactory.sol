// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IVeHemi} from "../interfaces/IVeHemi.sol";

contract PositionFactory is Ownable2Step {
    using SafeERC20 for IERC20;

    IVeHemi constant veHemi = IVeHemi(0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89);
    IERC20 constant hemi = IERC20(0x99e3dE3817F6081B2568208337ef83295b7f591D);

    enum Status {
        NONE,
        PENDING,
        CREATED
    }

    mapping(bytes32 => Status) public created;

    event StatusUpdated(
        bytes32 indexed hash,
        address indexed user_,
        uint256 amount_,
        uint256 duration_,
        Status status
    );
    event PositionCreated(
        bytes32 indexed hash,
        address indexed user_,
        uint256 amount_,
        uint256 duration_,
        bool transferable_,
        bool forfeitable_
    );

    error PositionCreatedAlready();
    error InvalidArrays();

    constructor(address owner_) Ownable(owner_) {}

    function create(
        address user_,
        uint256 amount_,
        uint256 duration_,
        bool transferable_,
        bool forfeitable_
    ) external {
        bytes32 _hash = keccak256(abi.encodePacked(user_, amount_, duration_));

        Status _status = created[_hash];

        if (_status != Status.PENDING) revert PositionCreatedAlready();

        hemi.safeTransferFrom(msg.sender, address(this), amount_);
        hemi.forceApprove(address(veHemi), amount_);
        veHemi.createLockFor(amount_, duration_, user_, transferable_, forfeitable_);

        created[_hash] = Status.CREATED;

        emit PositionCreated(_hash, user_, amount_, duration_, transferable_, forfeitable_);
    }

    function updateStatus(
        address[] calldata users_,
        uint256[] calldata amounts_,
        uint256[] calldata durations_,
        Status status_
    ) external onlyOwner {
        uint256 _length = users_.length;

        if (_length != amounts_.length || _length != durations_.length) revert InvalidArrays();

        for (uint256 i; i < _length; ++i) {
            uint256 _amount = amounts_[i];
            uint256 _duration = durations_[i];
            address _user = users_[i];

            bytes32 _hash = keccak256(abi.encodePacked(_user, _amount, _duration));

            created[_hash] = status_;

            emit StatusUpdated(_hash, _user, _amount, _duration, status_);
        }
    }
}
