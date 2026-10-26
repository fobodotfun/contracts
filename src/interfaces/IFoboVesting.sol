// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice FoboVesting: locks ERC-20 tokens for a beneficiary and releases them linearly. Spec: packages/contracts/README.md.
interface IFoboVesting {
    struct Lock {
        address token;
        uint64 start; // unix seconds
        uint32 duration; // seconds: months x MONTH
        address beneficiary;
        uint256 amount; // what the lock received
        uint256 claimed; // paid out so far
    }

    event Locked(
        uint256 indexed id,
        address indexed token,
        address indexed beneficiary,
        address from,
        uint256 amount,
        uint64 start,
        uint32 duration
    );
    event Claimed(uint256 indexed id, uint256 amount);

    error BadMonths();
    error ZeroAddress();
    error ZeroAmount();
    error UnknownLock();
    error NothingToClaim();

    /// @notice Locks `amount` of `token` (pulled from the caller: approve first) for `beneficiary`, vesting linearly per
    ///         second over `months` (1, 3, 6 or 12) from now. The lock holds what actually arrived.
    function lock(address token, uint256 amount, uint8 months, address beneficiary) external returns (uint256 id);

    /// @notice Pays the lock's vested, unclaimed tokens to its beneficiary (anyone may trigger it).
    function claim(uint256 id) external returns (uint256 amount);

    function claimable(uint256 id) external view returns (uint256);
    function getLock(uint256 id) external view returns (Lock memory);
    function lockCount() external view returns (uint256);
    function locksOf(address beneficiary) external view returns (uint256[] memory);
    function locksOfToken(address token) external view returns (uint256[] memory);
}
