// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IERC20} from "./interface/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";

import {ScalpLP} from "./token/ScalpLP.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ScalpPositionMinter} from "./positions/ScalpPositionMinter.sol";

import {Pausable} from "./helpers/Pausable.sol";

import {IOptionPricing} from "./interface/IOptionPricing.sol";
import {IVolatilityOracle} from "./interface/IVolatilityOracle.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {IGmxRouter} from "./interface/IGmxRouter.sol";
import {IGmxHelper} from "./interface/IGmxHelper.sol";

import "hardhat/console.sol";

contract OptionScalp is
Ownable,
Pausable {

    using SafeERC20 for IERC20;

    // Base token
    IERC20 public base;
    // Quote token
    IERC20 public quote;
    // Scalp LP token
    ScalpLP public scalpLp;

    // Option pricing
    IOptionPricing public optionPricing;
    // Volatility oracle
    IVolatilityOracle public volatilityOracle;
    // Price oracle
    IPriceOracle public priceOracle;
    // Scalp position minter
    ScalpPositionMinter public scalpPositionMinter;

    // GMX Helper
    IGmxHelper public gmxHelper;
    // GMX Router
    IGmxRouter public gmxRouter;
    
    uint[] public timeframes = [
        5 minutes,
        15 minutes,
        30 minutes
    ];

    // Minimum margin to open a position
    uint public minimumMargin = 5e6; // $5

    // Fees for opening position
    uint public feeOpenPosition = 5000000; // 0.05%

    // Percentage threshold above (entry - margin) when liquidate() is callable
    uint public liquidationThresholdPercentage = 2500000; // 0.025%

    // Minimum absolute threshold in quote asset above (entry - margin) when liquidate() is callable
    uint public minimumAbsoluteLiquidationThreshold = 5e6; // $5

    uint public constant divisor = 1e8;

    // Scalp positions
    mapping(uint => ScalpPosition) public scalpPositions;

    struct ScalpPosition {
        // Is position open
        bool isOpen;
        // Total size in quote asset
        uint size;
        // Amount of base asset swapped to
        uint swapped;
        // Entry price
        uint entry;
        // Margin provided
        uint margin;
        // Premium for position
        uint premium;
        // Fees for position
        uint fees;
        // Final PNL of position
        int pnl;
        // Opened at timestamp
        uint openedAt;
        // How long position is to be kept open
        uint timeframe;
    }

    // Deposit event
    event Deposit(
        uint amount,
        address indexed sender
    );

    // Withdraw event
    event Withdraw(
        uint amount,
        address indexed sender
    );

    // Open position event
    event OpenPosition(
        uint id,
        uint size,
        address indexed user
    );

    // Close position event
    event ClosePosition(
        uint id,
        int pnl,
        address indexed user
    );

    // Liquidate position event
    event LiquidatePosition(
        uint id,
        int pnl,
        address indexed liquidator
    );

    // Expire position event
    event ExpirePosition(
        uint id,
        int pnl,
        address indexed sender
    );

    constructor(
        address _base,
        address _quote,
        address _optionPricing,
        address _volatilityOracle,
        address _priceOracle,
        address _gmxRouter,
        address _gmxHelper,
        uint _minimumMargin
    ) {
        require(_base != address(0), "Invalid base token");
        require(_quote != address(0), "Invalid quote token");
        require(_optionPricing != address(0), "Invalid option pricing");
        require(_volatilityOracle != address(0), "Invalid volatility oracle");
        require(_priceOracle != address(0), "Invalid price oracle");

        base = IERC20(_base);
        quote = IERC20(_quote);
        optionPricing = IOptionPricing(_optionPricing);
        volatilityOracle = IVolatilityOracle(_volatilityOracle);
        priceOracle = IPriceOracle(_priceOracle);
        gmxHelper = IGmxHelper(_gmxHelper);
        gmxRouter = IGmxRouter(_gmxRouter);
        minimumMargin = _minimumMargin;

        scalpPositionMinter = new ScalpPositionMinter();

        base.approve(_gmxRouter, type(uint256).max);

        scalpLp = new ScalpLP(
            address(this),
            address(quote),
            base.symbol(),
            quote.symbol()
        );
        quote.approve(address(scalpLp), type(uint256).max);
    }

  /// @notice Internal function to handle swaps using GMX
  /// @param from Address of the token to sell
  /// @param to Address of the token to buy
  /// @param targetAmountOut Target amount of to token we want to receive
  function _swapUsingGmxExactOut(
        address from,
        address to,
        uint256 targetAmountOut
    ) internal returns (uint exactAmountOut) {
      address[] memory path;

      path = new address[](2);
      path[0] = address(from);
      path[1] = address(to);

      uint balance = IERC20(to).balanceOf(address(this));
      uint amountIn = gmxHelper.getAmountIn(targetAmountOut, 0, to, from);
      gmxRouter.swap(path, amountIn, 0, address(this));
      exactAmountOut = IERC20(to).balanceOf(address(this)) - balance;
  }

    // Deposit quote assets to LP
    // @param amount Amount of quote asset to deposit to LP
    function deposit(
        uint amount
    ) public {
        quote.transferFrom(msg.sender, address(this), amount);
        scalpLp.deposit(amount, msg.sender);
        emit Deposit(
            amount,
            msg.sender
        );
    }

    // Withdraw LP position
    // @param amount Amount of LP positions to withdraw
    function withdraw(
        uint amount
    ) public {
        scalpLp.redeem(amount, msg.sender, msg.sender);
        emit Withdraw(
            amount,
            msg.sender
        );
    }

    /// @notice Opens a position against the base asset
    function openPosition(
        uint size,
        uint timeframeIndex,
        uint margin
    ) public returns (uint id) {
        require(size <= scalpLp.totalAvailableAssets(), "Not enough available liquidity");
        require(timeframeIndex < timeframes.length, "Invalid timeframe");
        require(margin >= minimumMargin, "Insufficient margin");

        // Calculate premium for ATM option in quote
        uint premium = calcPremium(getMarkPrice(), size, timeframes[timeframeIndex]);

        // Calculate opening fees in quote
        uint openingFees = calcFees(size / 10 ** 2);

        // Total fees in quote
        uint totalFee = premium + openingFees;

        // Transfer fees + margin
        quote.transferFrom(msg.sender, address(this), (totalFee + margin));

        // Transfer fees to LP
        scalpLp.addProceeds(totalFee);

        // Lock `size` liquidity
        scalpLp.lockLiquidity(size);

        // Swap to base assets
        uint swapped = _swapUsingGmxExactOut(
            address(quote),
            address(base),
            size / getMarkPrice()
        );

        // 1e18 / 1e6 * x = 1e8
        // 1e8 * 1e6 / 1e18

        uint entry = swapped / size *  (base.decimals() / (divisor * quote.decimals()));
        // Generate scalp position NFT
        id = scalpPositionMinter.mint(msg.sender);
        scalpPositions[id] = ScalpPosition({
            isOpen: true,
            size: size,
            swapped: swapped,
            entry: entry,
            margin: margin,
            premium: premium,
            fees: openingFees,
            pnl: 0,
            openedAt: block.timestamp,
            timeframe: timeframes[timeframeIndex]
        });

        emit OpenPosition(
            id,
            size,
            msg.sender
        );
    }

    /// @notice Closes an open position
    /// @param id Closes an open position
    function closePosition(
        uint id
    ) public {
        require(scalpPositions[id].isOpen, "Invalid position ID");
        require(
            IERC721(scalpPositionMinter).ownerOf(id) == msg.sender, 
            "Sender must be position owner"
        );

        // Swap back to quote asset
        uint finalSize = _swapUsingGmxExactOut(
            address(base),
            address(quote),
            gmxHelper.getAmountOut(address(quote), address(base), scalpPositions[id].swapped)
        );

        int pnl = (int)(finalSize - scalpPositions[id].size);
        scalpLp.unlockLiquidity(scalpPositions[id].size);
        if (pnl > 0) {
            quote.transfer(msg.sender, (uint)((int)(scalpPositions[id].margin) + pnl));
        } else {
            require((int)(scalpPositions[id].margin) > pnl, "Insufficient margin");
            quote.transfer(msg.sender, (uint)((int)(scalpPositions[id].margin) + pnl));
        }
        emit ClosePosition(
            id,
            pnl,
            msg.sender
        );
    }

    /// @notice Liquidates an undercollateralized open position
    /// @param id ID of position
    function liquidate(
        uint id
    ) public {
        require(scalpPositions[id].isOpen, "Invalid position ID");
        require(isLiquidatable(id), "Position is not in liquidation range");

        address positionOwner = IERC721(scalpPositionMinter).ownerOf(id);
        // Swap back to quote asset
        uint amountIn = scalpPositions[id].swapped;
        uint finalSize = _swapUsingGmxExactOut(
            address(base),
            address(quote),
            gmxHelper.getAmountOut(address(quote), address(base), amountIn)
        );

        int pnl = (int)(finalSize - scalpPositions[id].size);
        scalpLp.unlockLiquidity(scalpPositions[id].size);
        if (pnl > 0) {
            quote.transfer(positionOwner, (uint)((int)(scalpPositions[id].margin) + pnl));
        } else {
            if ((int)(scalpPositions[id].margin) > pnl)
                quote.transfer(positionOwner, (uint)((int)(scalpPositions[id].margin) + pnl));
        }
        emit LiquidatePosition(
            id,
            pnl,
            msg.sender
        );
    }

    /// @notice Returns whether an open position is liquidatable
    function isLiquidatable(uint id) 
    public
    view
    returns (bool) {
        uint amountIn = scalpPositions[id].swapped;
        uint sizeAfterSwap = gmxHelper.getAmountOut(address(quote), address(base), amountIn);
        
        return 
            sizeAfterSwap <= (scalpPositions[id].size - minimumAbsoluteLiquidationThreshold) ||
            sizeAfterSwap <= 
                (
                    scalpPositions[id].size - 
                    (scalpPositions[id].size * liquidationThresholdPercentage / divisor)
                );
    }

    /// @notice Expires an open position post-expiry timestamp
    /// @param id ID of position
    function expirePosition(
        uint id
    ) public {
        require(scalpPositions[id].isOpen, "Invalid position ID");
        require(scalpPositions[id].openedAt + scalpPositions[id].timeframe >= block.timestamp, "Position has not expired");
        require(!isLiquidatable(id), "Please call liquidate()");

        address positionOwner = IERC721(scalpPositionMinter).ownerOf(id);
        // Swap back to quote asset
        uint finalSize = _swapUsingGmxExactOut(
            address(base),
            address(quote),
            gmxHelper.getAmountOut(address(quote), address(base), scalpPositions[id].swapped)
        );

        int pnl = (int)(finalSize - scalpPositions[id].size);
        scalpLp.unlockLiquidity(scalpPositions[id].size);
        if (pnl > 0) {
            quote.transfer(positionOwner, (uint)((int)(scalpPositions[id].margin) + pnl));
        } else {
            require((int)(scalpPositions[id].margin) > pnl, "Insufficient margin");
            quote.transfer(positionOwner, (uint)((int)(scalpPositions[id].margin) + pnl));
        }
        emit ExpirePosition(
            id,
            pnl,
            msg.sender
        );

    }

    /// @notice Allow only scalp LP contract to claim collateral (quote assets)
    /// @param amount Amount of quote assets to transfer
    function claimCollateral(uint amount) 
    public {
        require(msg.sender == address(scalpLp), "Only Scalp LP contract can claim collateral");
        quote.transfer(msg.sender, amount);
    }

    /// @notice External function to return the volatility
    /// @param strike Strike of option
    function getVolatility(uint strike)
    public
    view
    returns (uint volatility) {
        volatility =
        uint(volatilityOracle.getVolatility(
            strike
        ));
    }

    /// @notice Internal function to calculate premium
    /// @param strike Strike of option
    /// @param size Amount of option
    function calcPremium(
        uint strike,
        uint size,
        uint timeToExpiry
    )
    internal
    view
    returns (uint premium) {
        premium = (uint(optionPricing.getOptionPrice(
            false, // ATM options: does not matter if call or put
            timeToExpiry,
            strike,
            strike,
            getVolatility(strike)
        )) * (size / strike));
        
        premium = premium / (divisor / uint(10 ** quote.decimals()));
    }

    /// @notice Internal function to calculate fees
    /// @param amount Value of option in USD (ie6)
    function calcFees(
        uint amount
    )
    internal
    view
    returns (uint fees) {
        fees = (amount * feeOpenPosition) / (100 * divisor);
    }

    /// @notice Public function to retrieve price of base asset from oracle
    /// @param price Mark price
    function getMarkPrice()
    public
    view
    returns (uint price) {
        price = uint(priceOracle.getUnderlyingPrice());
    }

}
