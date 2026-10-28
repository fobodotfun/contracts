// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice OpenZeppelin's two-step ownership (the owner is a Safe), without renouncing: an ownerless contract could never
///         rotate its keys or recover from a bad registrar again.
abstract contract Owned is Ownable2Step {
    error RenounceDisabled();

    constructor(address owner_) Ownable(owner_) {}

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
