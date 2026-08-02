// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {LibString} from "solmate/src/utils/LibString.sol";

/// @notice One token per physical card held in custody. Minted by the Booster on pack reveal.
/// Burning via redeem() requests physical shipment of the underlying card.
contract CardVault is ERC721, Owned {
    address public booster;
    uint256 public nextId = 1;
    mapping(uint256 => uint16) public cardIdOf;
    string public baseURI;

    event RedemptionRequested(uint256 indexed tokenId, uint16 indexed cardId, address indexed owner);

    error OnlyBooster();
    error NotTokenOwner();
    error BoosterAlreadySet();

    constructor(string memory _baseURI) ERC721("Berrybox Card", "CARD") Owned(msg.sender) {
        baseURI = _baseURI;
    }

    function setBooster(address _booster) external onlyOwner {
        if (booster != address(0)) revert BoosterAlreadySet();
        booster = _booster;
    }

    function mint(address to, uint16 cardId) external returns (uint256 tokenId) {
        if (msg.sender != booster) revert OnlyBooster();
        tokenId = nextId++;
        cardIdOf[tokenId] = cardId;
        _safeMint(to, tokenId);
    }

    function redeem(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        uint16 cardId = cardIdOf[tokenId];
        _burn(tokenId);
        emit RedemptionRequested(tokenId, cardId, msg.sender);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return string.concat(baseURI, LibString.toString(cardIdOf[tokenId]));
    }
}
