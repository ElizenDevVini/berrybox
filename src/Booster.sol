// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {CardOracle} from "./CardOracle.sol";
import {CardVault} from "./CardVault.sol";

/// @notice Sealed pack token (0 decimals, 1 token = 1 pack) plus the box manifest and
/// commit-reveal opening. The full box contents are public from day one; only the draw
/// order is unknown. Each pack maps to exactly one card.
///
/// Randomness is blockhash-based commit-reveal: fine for a local demo, manipulable by a
/// block producer in production. Upgrade path is VRF.
contract Booster is ERC20, Owned {
    struct Pending {
        uint64 blockNumber;
        uint32 count;
    }

    CardOracle public immutable oracle;
    CardVault public immutable vault;
    uint16[] internal remaining;
    mapping(address => Pending) public pending;

    event BoxLoaded(uint256 cards, address inventoryHolder);
    event PackCommitted(address indexed opener, uint256 count, uint256 blockNumber);
    event PackOpened(address indexed opener, uint16 indexed cardId, uint256 tokenId);

    error BoxAlreadyLoaded();
    error NothingPending();
    error RevealTooEarly();
    error RevealWindowExpired();
    error NotExpired();

    constructor(CardOracle _oracle, CardVault _vault) ERC20("Berrybox Pack", "PACK", 0) Owned(msg.sender) {
        oracle = _oracle;
        vault = _vault;
    }

    /// @dev One-time load. Mints one pack per card to the inventory holder (the hook).
    function loadBox(uint16[] calldata cardIds, address inventoryHolder) external onlyOwner {
        if (remaining.length != 0 || totalSupply != 0) revert BoxAlreadyLoaded();
        remaining = cardIds;
        _mint(inventoryHolder, cardIds.length);
        emit BoxLoaded(cardIds.length, inventoryHolder);
    }

    /// @notice Burn packs now, draw cards in reveal() one block later.
    function open(uint256 count) external {
        _burn(msg.sender, count);
        Pending storage p = pending[msg.sender];
        p.count += uint32(count);
        p.blockNumber = uint64(block.number);
        emit PackCommitted(msg.sender, count, block.number);
    }

    function reveal() external returns (uint16[] memory cards) {
        Pending memory p = pending[msg.sender];
        if (p.count == 0) revert NothingPending();
        if (block.number <= p.blockNumber) revert RevealTooEarly();
        bytes32 bh = blockhash(p.blockNumber);
        if (bh == bytes32(0)) revert RevealWindowExpired(); // >256 blocks passed; call rearm()

        delete pending[msg.sender];
        cards = new uint16[](p.count);
        for (uint256 i = 0; i < p.count; i++) {
            uint256 idx = uint256(keccak256(abi.encodePacked(bh, msg.sender, i))) % remaining.length;
            uint16 cardId = remaining[idx];
            remaining[idx] = remaining[remaining.length - 1];
            remaining.pop();
            uint256 tokenId = vault.mint(msg.sender, cardId);
            cards[i] = cardId;
            emit PackOpened(msg.sender, cardId, tokenId);
        }
    }

    /// @dev Re-arms an expired commit. This allows a re-roll after 256 blocks of
    /// deliberate non-reveal, which is an accepted demo tradeoff (VRF removes it).
    function rearm() external {
        Pending storage p = pending[msg.sender];
        if (p.count == 0) revert NothingPending();
        if (blockhash(p.blockNumber) != bytes32(0) && block.number > p.blockNumber) revert NotExpired();
        p.blockNumber = uint64(block.number);
    }

    /// @notice Expected value of one uniform draw from the unopened cards, USDC 6 decimals.
    function evPerPack() public view returns (uint256) {
        uint256 n = remaining.length;
        if (n == 0) return 0;
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            sum += oracle.price(remaining[i]);
        }
        return sum / n;
    }

    function remainingCards() external view returns (uint16[] memory) {
        return remaining;
    }

    function packsRemaining() external view returns (uint256) {
        return remaining.length;
    }
}
