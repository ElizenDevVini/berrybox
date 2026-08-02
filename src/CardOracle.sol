// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";

/// @notice Per-card price feed, pushed off-chain from TCG market data. Prices in USDC (6 decimals).
contract CardOracle is Owned {
    mapping(uint16 => uint256) public price;

    event PriceSet(uint16 indexed cardId, uint256 price);

    error LengthMismatch();

    constructor() Owned(msg.sender) {}

    function setPrices(uint16[] calldata ids, uint256[] calldata prices) external onlyOwner {
        if (ids.length != prices.length) revert LengthMismatch();
        for (uint256 i = 0; i < ids.length; i++) {
            price[ids[i]] = prices[i];
            emit PriceSet(ids[i], prices[i]);
        }
    }
}
