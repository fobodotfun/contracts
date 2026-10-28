// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFoboVesting} from "./interfaces/IFoboVesting.sol";

/// @title FoboVesting
/// @notice Locks ERC-20 tokens for a beneficiary and releases them linearly per second over 1, 3, 6 or 12 months.
///         FoboFactory.launch locks a creator's dev buy here when the creator picks a vest length
///         (LaunchParams.vestMonths); anyone can lock any token with `lock`. No owner, no upgrades, no early exit: a
///         lock's tokens only ever leave as its vested share, to its beneficiary. Like FoboRevenue.claim, anyone can
///         trigger a claim and it always pays the beneficiary. Spec: packages/contracts/README.md §16.
/// @dev A fee-on-transfer token is locked at what arrived (balance difference). Rebasing tokens are not supported.
contract FoboVesting is IFoboVesting, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice One month: a twelfth of a 365-day year (12 months = exactly 365 days).
    uint256 public constant MONTH = 365 days / 12;

    Lock[] internal _locks;
    mapping(address => uint256[]) internal _byBeneficiary;
    mapping(address => uint256[]) internal _byToken;

    /// @inheritdoc IFoboVesting
    function lock(address token, uint256 amount, uint8 months, address beneficiary)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (months != 1 && months != 3 && months != 6 && months != 12) revert BadMonths();
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        id = _locks.length;
        uint32 duration = uint32(months * MONTH);
        _locks.push(
            Lock({
                token: token,
                start: uint64(block.timestamp),
                duration: duration,
                beneficiary: beneficiary,
                amount: received,
                claimed: 0
            })
        );
        _byBeneficiary[beneficiary].push(id);
        _byToken[token].push(id);
        emit Locked(id, token, beneficiary, msg.sender, received, uint64(block.timestamp), duration);
    }

    /// @inheritdoc IFoboVesting
    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        if (id >= _locks.length) revert UnknownLock();
        Lock storage l = _locks[id];
        amount = _vested(l) - l.claimed;
        if (amount == 0) revert NothingToClaim();
        l.claimed += amount;
        emit Claimed(id, amount);
        IERC20(l.token).safeTransfer(l.beneficiary, amount);
    }

    /// @inheritdoc IFoboVesting
    function claimable(uint256 id) external view returns (uint256) {
        if (id >= _locks.length) revert UnknownLock();
        Lock storage l = _locks[id];
        return _vested(l) - l.claimed;
    }

    /// @inheritdoc IFoboVesting
    function getLock(uint256 id) external view returns (Lock memory) {
        if (id >= _locks.length) revert UnknownLock();
        return _locks[id];
    }

    function lockCount() external view returns (uint256) {
        return _locks.length;
    }

    function locksOf(address beneficiary) external view returns (uint256[] memory) {
        return _byBeneficiary[beneficiary];
    }

    function locksOfToken(address token) external view returns (uint256[] memory) {
        return _byToken[token];
    }

    /// @dev Vested so far: linear per second from start, all of it at start + duration.
    function _vested(Lock storage l) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - l.start;
        if (elapsed >= l.duration) return l.amount;
        return Math.mulDiv(l.amount, elapsed, l.duration);
    }
}
