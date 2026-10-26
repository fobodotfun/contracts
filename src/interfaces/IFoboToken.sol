// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The ERC-20 every launch deploys (FoboToken): fixed supply, holders can burn their own.
interface IFoboToken is IERC20 {
    /// @notice Burns the caller's tokens; total supply goes down (the floor treats burned tokens as gone).
    function burn(uint256 amount) external;
}
