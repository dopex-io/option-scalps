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

    int24 maxTickSpaceMultiplier = 100;

    uint256 public maxFundingTime = 4 hours;

    uint256 public fundingRate = 1825000000; // 18.25% annualized (0.002% per hour)

    // Used for percentages
    uint256 public constant divisor = 1e8;

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

    /// @notice Admin function to add an option scalp
    function addOptionScalps(address[] memory _optionScalps) external onlyOwner {
      for (uint i = 0; i < _optionScalps.length; i++) {
        require(_optionScalps[i] != address(0), "Invalid option scalp address");
        optionScalps[_optionScalps[i]] = true;
        IERC20(OptionScalp(_optionScalps[i]).quote()).safeApprove(_optionScalps[i], MAX);
        IERC20(OptionScalp(_optionScalps[i]).base()).safeApprove(_optionScalps[i], MAX);
      }
    }

    /// @notice Internal function to calc. amounts to deposit given a locked liquidity target
    /// @param lockedLiquidity Amount of target locked liquidity
    /// @param optionScalp the OptionScalp contract we use
    /// @param isShort If true the position will be a short
    /// @param tick0 Start tick of the position to create
    /// @param tick1 End tick of the position to create
    function calcAmounts(uint256 lockedLiquidity, OptionScalp optionScalp, bool isShort, int24 tick0, int24 tick1) internal returns (address token0, address token1, uint256 amount0, uint256 amount1) {
          address base = address(optionScalp.base());
          address quote = address(optionScalp.quote());
          IUniswapV3Pool pool = IUniswapV3Pool(uniswapV3Factory.getPool(base, quote, 500));
          token0 = pool.token0();
          token1 = pool.token1();

          int24 tickSpacing = pool.tickSpacing();
          (,int24 tick,,,,,) = pool.slot0();

          if (tick > tick0) require(tick - tick0 <= tickSpacing * maxTickSpaceMultiplier, "Price is too far");
          else require(tick0 - tick <= tickSpacing * maxTickSpaceMultiplier, "Price is too far");

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

    /// @notice Internal function to create a new Uniswap V3 position
    /// @param optionScalp Address of option scalp
    /// @param tick0 Start tick of the position to create
    /// @param tick1 End tick of the position to create
    /// @param amount Amount to deposit
    /// @param isShort If true the position will be a short
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

    /// @notice Create a new OpenOrder
    /// @param optionScalp Address of option scalp
    /// @param isShort If true the position will be a short
    /// @param size Size of position (quoteDecimals)
    /// @param timeframeIndex Position of the array
    /// @param collateral Total collateral posted by user
    /// @param tick0 Start tick of the position to create
    /// @param tick1 End tick of the position to create
    function createOpenOrder(
      OptionScalp optionScalp,
      bool isShort,
      uint256 size,
      uint256 timeframeIndex,
      uint256 collateral, // margin + fees + premium
      int24 tick0,
      int24 tick1
    )
    nonReentrant
    external {
      require(optionScalps[address(optionScalp)], "Invalid option scalp contract");

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
        optionScalp: address(optionScalp),
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

    /// @notice Fill a OpenOrder
    /// @param _id ID of the OpenOrder
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

    /// @notice Create a CloseOrder
    /// @param optionScalp Address of option scalp
    /// @param id Order id
    /// @param tick0 Start tick of the position to create
    /// @param tick1 End tick of the position to create
    function createCloseOrder(
        OptionScalp optionScalp,
        uint256 id,
        int24 tick0,
        int24 tick1
    )
    nonReentrant
    external {
      require(optionScalps[address(optionScalp)], "Invalid option scalp contract");
        
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
        optionScalp: address(optionScalp),
        filled: false,
        positionId: positionId
     });
    }

    /// @notice Fill a CloseOrder
    /// @param _id ID of the CloseOrder
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

    /// @notice Cancel OpenOrder
    /// @param _id ID of the OpenOrder
    function cancelOpenOrder(uint _id)
    nonReentrant
    external {
      require(
        !openOrders[_id].filled &&
        !openOrders[_id].cancelled,
        "Order is not active and unfilled"
      );

      if (openOrders[_id].timestamp + maxFundingTime <= block.timestamp) require(msg.sender == openOrders[_id].user, "Only order creator can call cancel before expiry");
      openOrders[_id].cancelled = true;

      OptionScalp optionScalp = OptionScalp(openOrders[_id].optionScalp);

      IUniswapV3Pool pool = IUniswapV3Pool(uniswapV3Factory.getPool(address(optionScalp.base()), address(optionScalp.quote()), 500));

      optionScalp.burnUniswapV3Position(
          pool,
          openOrders[_id].positionId,
          !openOrders[_id].isShort
      );

      uint256 fees = (openOrders[_id].collateral * fundingRate / divisor) / uint256(365 days);

      optionScalp.settleOpenOrderDeletion(openOrders[_id].user, openOrders[_id].isShort, openOrders[_id].collateral - fees, fees);

      emit CancelOrder(_id, msg.sender);
    }

    /// @notice Cancel CloseOrder
    /// @param _id ID of the CloseOrder
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

    /// @notice Returns true is CloseOrder is active
    /// @param _id ID of the CloseOrder
    function isCloseOrderActive(uint256 _id) public returns (bool) {
        return !closeOrders[_id].filled && closeOrders[_id].optionScalp != address(0);
    }
}
