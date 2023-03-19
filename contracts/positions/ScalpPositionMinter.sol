//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// Contracts
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";

contract ScalpPositionMinter is 
  ReentrancyGuard,
  ERC721('OP-ScalpPosition', 'OPSP'),
  ERC721Enumerable,
  ERC721Burnable,
  Ownable {

  using Counters for Counters.Counter;

  /// @dev Token ID counter for straddle positions
  Counters.Counter private _tokenIdCounter;

  address public optionScalpContract;

  constructor() {
    optionScalpContract = msg.sender;
    _tokenIdCounter.increment();
  }

  function setScalpContract(address _optionScalpContract)
  public
  onlyOwner {
    optionScalpContract = _optionScalpContract;
  }

  function mint(address to) public returns (uint tokenId) {
    require(
      msg.sender == optionScalpContract, 
      "Only option scalp contract can mint an option scalp position token"
    );
    tokenId = _tokenIdCounter.current();
    _tokenIdCounter.increment();
    _safeMint(to, tokenId);
    return tokenId;
  }

  function burn(uint256 id) public override {
    require(
      msg.sender == optionScalpContract,
      "Only option scalp contract can mint an option scalp position token"
    );
    _burn(id);
  }

  // The following functions are overrides required by Solidity.
  function _beforeTokenTransfer(
      address from,
      address to,
      uint256 tokenId,
      uint256 batchSize
  ) internal override(ERC721, ERC721Enumerable) {
      super._beforeTokenTransfer(from, to, tokenId, batchSize);
  }

  function supportsInterface(bytes4 interfaceId)
      public
      view
      override(ERC721, ERC721Enumerable)
      returns (bool)
  {
      return super.supportsInterface(interfaceId);
  }

}