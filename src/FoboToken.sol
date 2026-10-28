// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IFoboToken} from "./interfaces/IFoboToken.sol";

/// @title FoboToken
/// @notice Plain ERC-20 (OpenZeppelin) with a fixed supply of 1,000,000,000 (18 decimals), minted once to the deployer
///         (the factory). No owner, no mint function, no fees on transfer, no blacklist. Holders can burn their own
///         tokens (the floor treats burned tokens as gone).
contract FoboToken is ERC20, ERC20Burnable, IFoboToken {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @dev OpenZeppelin's burn unchanged. Solidity requires this override because both ERC20Burnable and IFoboToken
    ///      declare burn.
    function burn(uint256 amount) public override(ERC20Burnable, IFoboToken) {
        super.burn(amount);
    }
}
