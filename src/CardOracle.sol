// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";

/// @notice Per-card price feed, pushed off-chain from TCG market data. Prices in USDC (6 decimals).
contract CardOracle is Owned {
    mapping(uint16 => uint256) public price;
    /// @notice USD per ETH, 6 decimals. Used to quote packs in native ETH.
    uint256 public ethUsd;

    event PriceSet(uint16 indexed cardId, uint256 price);
    event EthUsdSet(uint256 price);

    error LengthMismatch();

    constructor() Owned(msg.sender) {}

    function setEthUsd(uint256 v) external onlyOwner {
        ethUsd = v;
        emit EthUsdSet(v);
    }

    function setPrices(uint16[] calldata ids, uint256[] calldata prices) external onlyOwner {
        if (ids.length != prices.length) revert LengthMismatch();
        for (uint256 i = 0; i < ids.length; i++) {
            price[ids[i]] = prices[i];
            emit PriceSet(ids[i], prices[i]);
        }
    }
}
