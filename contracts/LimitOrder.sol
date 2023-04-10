// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IERC20} from "./interface/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {ContractWhitelist} from "./helpers/ContractWhitelist.sol";

import {ScalpLP} from "./token/ScalpLP.sol";

import {OptionScalp} from "./OptionScalp.sol";
import {ScalpPositionMinter} from "./positions/ScalpPositionMinter.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Pausable} from "./helpers/Pausable.sol";

contract LimitOrder is Ownable, Pausable, ReentrancyGuard, ContractWhitelist, ERC721Holder {
    using SafeERC20 for IERC20;

    uint256 MAX = 2**256 - 1;

    mapping (address => bool) optionScalps;

    mapping (uint => Order) public orders;

    uint public orderCount;

    struct Order {
      uint id;
      address optionScalp;
      address user;
      bool isShort;
      bool filled;
      bool cancelled;
      uint256 size;
      uint256 timeframeIndex;
      uint256 collateral;
      uint256 entryLimit;
      uint256 expiry;
      uint256 lockedLiquidity;
    }

    event NewOrder(uint id, address user);

    event CancelOrder(uint id, address user);

    function addOptionScalps(address[] memory _optionScalps) external {
      for (uint i = 0; i < _optionScalps.length; i++) {
        require(_optionScalps[i] != address(0), "Invalid option scalp address");
        optionScalps[_optionScalps[i]] = true;
        IERC20(OptionScalp(_optionScalps[i]).quote()).safeApprove(_optionScalps[i], MAX);
        IERC20(OptionScalp(_optionScalps[i]).base()).safeApprove(_optionScalps[i], MAX);
      }
    }

    function createOrder(
      address _optionScalp,
      bool isShort,
      uint256 size,
      uint256 timeframeIndex,
      uint256 collateral, // margin + fees + premium
      uint256 entryLimit,
      uint256 expiry
    )
    nonReentrant
    external
    returns (uint id) {
      require(optionScalps[_optionScalp], "Invalid option scalp contract");
      OptionScalp optionScalp = OptionScalp(_optionScalp);

      require(optionScalp.timeframes(timeframeIndex) != 0, "Invalid timeframe");
      require(collateral >= optionScalp.minimumMargin(), "Insufficient margin");
      require(size <= optionScalp.maxSize(), "Position exposure is too high");

      orders[orderCount] = Order({
        id: orderCount,
        optionScalp: _optionScalp,
        user: msg.sender,
        isShort: isShort,
        filled: false,
        cancelled: false,
        size: size,
        timeframeIndex: timeframeIndex,
        collateral: collateral,
        entryLimit: entryLimit,
        expiry: expiry,
        lockedLiquidity: isShort ? (10 ** optionScalp.baseDecimals()) * size / optionScalp.getMarkPrice() : size
      });

      (optionScalp.quote()).safeTransferFrom(
          msg.sender,
          address(this),
          collateral
      );

      (isShort ? ScalpLP(optionScalp.baseLp()) : ScalpLP(optionScalp.quoteLp())).lockLiquidity(orders[orderCount].lockedLiquidity);

      // TODO: create uniswap v3 orders

      emit NewOrder(
        orderCount,
        msg.sender
      );

      orderCount++;
    }

    function fillOrder(uint _id)
    nonReentrant
    external {
      require(
        !orders[_id].filled && 
        !orders[_id].cancelled &&
        block.timestamp <= orders[_id].expiry,
        "Order is not active and unfilled"
      );
      OptionScalp optionScalp = OptionScalp(orders[_id].optionScalp);

      uint markPrice = optionScalp.getMarkPrice();

      if (orders[_id].isShort) {
        require(
          markPrice <= orders[_id].entryLimit, 
          "Mark price must be lower than limit entry price"
        );
      } else {
        require(
          markPrice >= orders[_id].entryLimit, 
          "Mark price must be greater than limit entry price"
        );
      }

      // Calculate premium for ATM option in quote
      uint256 premium = optionScalp.calcPremium(
          markPrice,
          orders[_id].size,
          optionScalp.timeframes(orders[_id].timeframeIndex)
      );

      // Calculate opening fees in quote
      uint256 openingFees = optionScalp.calcFees(orders[_id].size);

      require(orders[_id].collateral > premium + openingFees, "Insufficient margin");

      (orders[_id].isShort ? ScalpLP(optionScalp.baseLp()) : ScalpLP(optionScalp.quoteLp())).unlockLiquidity(orders[_id].lockedLiquidity);
      // TODO: remove liquidity from Uniswap v3 and create position

      // ScalpPositionMinter(optionScalp.scalpPositionMinter()).transferFrom(address(this), orders[_id].user, id);
    }
    
    function cancelOrder(uint _id)
    nonReentrant
    external {
      require(
        !orders[_id].filled && 
        !orders[_id].cancelled, 
        "Order is not active and unfilled"
      );
      require(msg.sender == orders[_id].user, "Only order creator can call cancel");
      orders[_id].cancelled = true;

      OptionScalp optionScalp = OptionScalp(orders[_id].optionScalp);

      (optionScalp.quote()).safeTransferFrom(
          address(this),
          orders[_id].user,
          orders[_id].collateral
      );

      emit CancelOrder(_id, msg.sender);
    }
}