// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IERC20} from "./interface/IERC20.sol";
import {IUniswapV3Factory} from "./interface/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interface/IUniswapV3Pool.sol";
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

import "hardhat/console.sol";

contract LimitOrderManager is Ownable, Pausable, ReentrancyGuard, ContractWhitelist, ERC721Holder {
    using SafeERC20 for IERC20;

    uint256 MAX = 2**256 - 1;

    mapping (address => bool) optionScalps;

    mapping (uint => OpenOrder) public openOrders; // identifier -> openOrder

    mapping (uint => CloseOrder) public closeOrders; // scalpPositionId -> closeOrder

    IUniswapV3Factory uniswapV3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    uint public orderCount;

    struct OpenOrder {
      address optionScalp;
      address user;
      bool isShort;
      bool filled;
      bool cancelled;
      uint256 size;
      uint256 timeframeIndex;
      uint256 collateral;
      uint256 lockedLiquidity;
      uint256 positionId;
      uint256 timestamp;
    }

    struct CloseOrder {
      address optionScalp;
      bool filled;
      uint256 positionId;
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

    function calcAmounts(uint256 lockedLiquidity, OptionScalp optionScalp, bool isShort, int24 tick0, int24 tick1) internal returns (address token0, address token1, uint256 amount0, uint256 amount1) {
          address base = address(optionScalp.base());
          address quote = address(optionScalp.quote());
          IUniswapV3Pool pool = IUniswapV3Pool(uniswapV3Factory.getPool(base, quote, 500));
          token0 = pool.token0();
          token1 = pool.token1();

          int24 tickSpacing = pool.tickSpacing();

          require(tick1 - tick0 == tickSpacing, "Invalid ticks");

          if (base == token0) {
              // amount0 is base
              // amount1 is quote
              if (isShort) amount0 = lockedLiquidity;
              else amount1 = lockedLiquidity;
          }  else {
              // amount0 is quote
              // amount1 is base
              if (isShort) amount1 = lockedLiquidity;
              else amount0 = lockedLiquidity;
          }
    }

    function createPosition(OptionScalp optionScalp, int24 tick0, int24 tick1, uint256 amount, bool isShort) internal returns (uint256 positionId, uint256 lockedLiquidity) {
          lockedLiquidity = isShort ? (10 ** optionScalp.baseDecimals()) * amount / optionScalp.getMarkPrice() : amount;

          (address token0, address token1, uint256 amount0, uint256 amount1) = calcAmounts(lockedLiquidity, optionScalp, isShort, tick0, tick1);

          positionId = optionScalp.mintUniswapV3Position(
              token0,
              token1,
              tick0,
              tick1,
              amount0,
              amount1
          );
    }

    function createOpenOrder(
      address _optionScalp,
      bool isShort,
      uint256 size,
      uint256 timeframeIndex,
      uint256 collateral, // margin + fees + premium
      int24 tick0,
      int24 tick1
    )
    nonReentrant
    external {
      require(optionScalps[_optionScalp], "Invalid option scalp contract");
      OptionScalp optionScalp = OptionScalp(_optionScalp);

      require(optionScalp.timeframes(timeframeIndex) != 0, "Invalid timeframe");
      require(collateral >= optionScalp.minimumMargin(), "Insufficient margin");
      require(size <= optionScalp.maxSize(), "Position exposure is too high");

      (optionScalp.quote()).safeTransferFrom(
          msg.sender,
          address(this),
          collateral
      );

      (uint256 positionId, uint256 lockedLiquidity) = createPosition(
        optionScalp,
        tick0,
        tick1,
        size,
        isShort
      );

      (isShort ? ScalpLP(optionScalp.baseLp()) : ScalpLP(optionScalp.quoteLp())).lockLiquidity(lockedLiquidity);

      openOrders[orderCount] = OpenOrder({
        optionScalp: _optionScalp,
        user: msg.sender,
        isShort: isShort,
        filled: false,
        cancelled: false,
        size: size,
        timeframeIndex: timeframeIndex,
        collateral: collateral,
        lockedLiquidity: lockedLiquidity,
        positionId: positionId,
        timestamp: block.timestamp
      });

      emit NewOrder(
        orderCount,
        msg.sender
      );

      orderCount++;
    }

    function fillOpenOrder(uint _id)
    nonReentrant
    external {
      require(
        !openOrders[_id].filled &&
        !openOrders[_id].cancelled &&
        openOrders[_id].user != address(0),
        "Order is not active and unfilled"
      );
      OptionScalp optionScalp = OptionScalp(openOrders[_id].optionScalp);

      IUniswapV3Pool pool = IUniswapV3Pool(uniswapV3Factory.getPool(address(optionScalp.base()), address(optionScalp.quote()), 500));

      console.log("Burn Uniswap V3 Position");

      uint256 swapped = optionScalp.burnUniswapV3Position(
          pool,
          openOrders[_id].positionId,
          openOrders[_id].isShort
      );

      console.log("Open position from limit order");

      uint256 id = optionScalp.openPositionFromLimitOrder(
          swapped,
          openOrders[_id].isShort,
          openOrders[_id].collateral,
          openOrders[_id].size,
          openOrders[_id].timeframeIndex,
          openOrders[_id].lockedLiquidity
      );

      console.log("Opened!");

      openOrders[_id].filled = true;

      ScalpPositionMinter(optionScalp.scalpPositionMinter()).transferFrom(address(this), openOrders[_id].user, id);

      console.log("NFT has been transferred");
    }
    
    function createCloseOrder(
        address _optionScalp,
        uint256 id,
        int24 tick0,
        int24 tick1
    )
    nonReentrant
    external {
      require(optionScalps[_optionScalp], "Invalid option scalp contract");
      OptionScalp optionScalp = OptionScalp(_optionScalp);
        
      OptionScalp.ScalpPosition memory scalpPosition = optionScalp.getPosition(id);
      require(closeOrders[id].optionScalp == address(0), "There is already an open order for this position");

      (uint256 positionId, uint256 lockedLiquidity) = createPosition(
        optionScalp,
        tick0,
        tick1,
        scalpPosition.amountOut,
        !scalpPosition.isShort
      );

     closeOrders[id] = CloseOrder({
        optionScalp: _optionScalp,
        filled: false,
        positionId: positionId
     });
    }

    function fillCloseOrder(uint _id)
    nonReentrant
    external {
      require(
        !closeOrders[_id].filled &&
        closeOrders[_id].optionScalp != address(0),
        "Order is not active and unfilled"
      );
      OptionScalp optionScalp = OptionScalp(closeOrders[_id].optionScalp);

      OptionScalp.ScalpPosition memory scalpPosition = optionScalp.getPosition(_id);

      IUniswapV3Pool pool = IUniswapV3Pool(uniswapV3Factory.getPool(address(optionScalp.base()), address(optionScalp.quote()), 500));

      console.log("Burn Uniswap V3 Position");

      uint256 swapped = optionScalp.burnUniswapV3Position(
          pool,
          closeOrders[_id].positionId,
          !scalpPosition.isShort
      );

      console.log("Close position from limit order");

      console.log("Swapped");
      console.log(swapped);

      optionScalp.closePositionFromLimitOrder(
          _id,
          swapped
      );

      console.log("Closed!");

      closeOrders[_id].filled = true;
    }
    
    function cancelOpenOrder(uint _id)
    nonReentrant
    external {
      require(
        !openOrders[_id].filled &&
        !openOrders[_id].cancelled,
        "Order is not active and unfilled"
      );

      // TODO: allow bots to cancel orders after a certain number hours
      require(msg.sender == openOrders[_id].user, "Only order creator can call cancel");
      openOrders[_id].cancelled = true;

      OptionScalp optionScalp = OptionScalp(openOrders[_id].optionScalp);

      // TODO: subtract fees
      (optionScalp.quote()).safeTransferFrom(
          address(this),
          openOrders[_id].user,
          openOrders[_id].collateral
      );

      emit CancelOrder(_id, msg.sender);
    }

    function cancelCloseOrder(uint _id)
    nonReentrant
    external {
      require(
        isCloseOrderActive(_id),
        "Order is not active and unfilled"
      );

      OptionScalp optionScalp = OptionScalp(closeOrders[_id].optionScalp);
      require(msg.sender == optionScalp.positionOwner(_id) || optionScalps[msg.sender], "Sender not authorized");

      OptionScalp.ScalpPosition memory scalpPosition = optionScalp.getPosition(_id);

      IUniswapV3Pool pool = IUniswapV3Pool(uniswapV3Factory.getPool(address(optionScalp.base()), address(optionScalp.quote()), 500));

      uint256 swapped = optionScalp.burnUniswapV3Position(
          pool,
          closeOrders[_id].positionId,
          !scalpPosition.isShort
      );

      delete closeOrders[_id];

      emit CancelOrder(_id, msg.sender);
    }

    function isCloseOrderActive(uint256 _id) public returns (bool) {
        return !closeOrders[_id].filled && closeOrders[_id].optionScalp != address(0);
    }
}
