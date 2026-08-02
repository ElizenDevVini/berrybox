// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Local-demo USDC, 6 decimals, open mint.
contract MockUSDC is ERC20("Mock USDC", "USDC", 6) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
