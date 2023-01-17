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

    // GMX Helper
    IGmxHelper public gmxHelper;
    // GMX Router
    IGmxRouter public gmxRouter;
    
    uint[] public timeframes = [
        5 minutes,
        15 minutes,
        30 minutes
    ];

    uint public minimumMargin;

    // Fees for opening position
    uint public feeOpenPosition  = 5000000; // 0.05%

    uint public constant divisor = 1e8;
    
    // Position count
    uint public count;

    struct ScalpPosition {
        // Is position open
        bool isOpen;
        // Total size in quote asset
        uint size;
        // Amount of base asset swapped to
        uint swapped;
        // Margin provided
        uint margin;
        // Premium for position
        int premium;
        // Fees for position
        int fees;
        // Final PNL of position
        int pnl;
        // Opened at timestamp
        uint openedAt;
    }

    // Deposit event
    event Deposit(
        uint amount,
        address sender
    );

    // Withdraw event
    event Withdraw(
        uint amount,
        address sender
    );

    // Open position event
    event OpenPosition(
        uint id,
        uint size,
        address user
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
        scalpLp.deposit(amount, msg.sender);
        quote.transferFrom(msg.sender, address(this), amount);
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
        uint margin,
        uint minAmountOut
    ) public returns (uint id) {
        require(size <= scalpLp.totalAvailableAssets(), "Not enough available liquidity");
        require(timeframeIndex < timeframes.length, "Invalid timeframe");
        require(margin >= minimumMargin, "Insufficient margin");

        // Calculate premium for ATM option in quote
        uint premium = calcPremium(getMarkPrice(), size, timeframes[timeframeIndex]);

        // Calculate opening fees in quote
        uint openingFees = calcFees(true, size / 10 ** 2);

        // Total fees in quote
        uint totalFee = premium + openingFees;

        // Transfer fees + margin
        quote.transferFrom(msg.sender, (totalFee + margin));

        // Transfer fees to LP
        scalpLp.addProceeds(totalFee);

        // Lock `size` liquidity
        scalpLp.lockLiquidity(size);

        // Swap to base assets
        uint swapped = _swapUsingGmxExactOut(
            quote,
            base,
            minAmountOut
        );

        // Generate scalp position NFT
        id = ScalpPositionMinter.mint(msg.sender);
        scalpPositions[id] = ScalpPosition({
            isOpen: true,
            size: size,
            swapped: swapped,
            margin: margin,
            premium: premium,
            fees: fees,
            pnl: 0,
            openedAt: block.timestamp
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

    }

    /// @notice Liquidates an undercollateralized open position
    /// @param id ID of position
    function liquidate(
        uint id
    ) public {

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
    /// @param openingPosition True if is opening position (else is closing)
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
