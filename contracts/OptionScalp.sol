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
import {IUniswapV3Router} from "./interface/IUniswapV3Router.sol";
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
    // Scalp Base LP token
    ScalpLP public baseLp;
    // Scalp Quotee LP token
    ScalpLP public quoteLp;

    // Option pricing
    IOptionPricing public optionPricing;
    // Volatility oracle
    IVolatilityOracle public volatilityOracle;
    // Price oracle
    IPriceOracle public priceOracle;
    // Scalp position minter
    ScalpPositionMinter public scalpPositionMinter;

    // Uniswap V3 router
    IUniswapV3Router public uniswapV3Router;

    // GMX Helper
    IGmxHelper public gmxHelper;
    
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
        // Is short
        bool isShort;
        // Total size in quote asset
        uint size;
        // Amount received from swap
        uint amountOut;
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
        bool isQuote,
        uint amount,
        address indexed sender
    );

    // Withdraw event
    event Withdraw(
        bool isQuote,
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
        address _uniswapV3Router,
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
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
        gmxHelper = IGmxHelper(_gmxHelper);
        minimumMargin = _minimumMargin;

        scalpPositionMinter = new ScalpPositionMinter();

        base.approve(address(uniswapV3Router), type(uint256).max);
        quote.approve(address(uniswapV3Router), type(uint256).max);

        quoteLp = new ScalpLP(
            address(this),
            address(quote),
            base.symbol(),
            quote.symbol()
        );

        baseLp = new ScalpLP(
            address(this),
            address(base),
            base.symbol(),
            quote.symbol()
        );

        quote.approve(address(quoteLp), type(uint256).max);
        base.approve(address(baseLp), type(uint256).max);
    }

    /// @notice Internal function to handle swaps using Uniswap V3 exactOutput
    /// @param from Address of the token to sell
    /// @param to Address of the token to buy
    /// @param amountOut Target amount of to token we want to receive
    function _swapExactOut(
        address from,
        address to,
        uint256 amountOut
    ) internal returns (uint amountIn) {
      return uniswapV3Router.exactOutputSingle(IUniswapV3Router.ExactOutputSingleParams({
            tokenIn: from,
            tokenOut: to,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: amountOut,
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
      }));
    }

    /// @notice Internal function to handle swaps using Uniswap V3 exactIn
    /// @param from Address of the token to sell
    /// @param to Address of the token to buy
    /// @param amountOut Target amount of to token we want to receive
    function _swapExactIn(
        address from,
        address to,
        uint256 amountIn
    ) internal returns (uint amountOut) {
      return uniswapV3Router.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
            tokenIn: from,
            tokenOut: to,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
      }));
    }

    // Deposit assets
    // @param isQuote If true user deposits quote token (else base)
    // @param amount Amount of quote asset to deposit to LP
    function deposit(
        bool isQuote,
        uint amount
    ) public {
        if (isQuote) {
            quote.transferFrom(msg.sender, address(this), amount);
            quoteLp.deposit(amount, msg.sender);
        } else {
            base.transferFrom(msg.sender, address(this), amount);
            baseLp.deposit(amount, msg.sender);
        }

        emit Deposit(
            isQuote,
            amount,
            msg.sender
        );
    }

    // Withdraw
    // @param isQuote If true user withdraws quote token (else base)
    // @param amount Amount of LP positions to withdraw
    function withdraw(
        bool isQuote,
        uint amount
    ) public {
        if (isQuote) {
            quoteLp.redeem(amount, msg.sender, msg.sender);
        } else {
            baseLp.redeem(amount, msg.sender, msg.sender);
        }

        emit Withdraw(
            isQuote,
            amount,
            msg.sender
        );
    }

    /// @notice Opens a position against/in favour of the base asset
    /// If you short base is swapped to quote
    function openPosition(
        bool isShort,
        uint size,
        uint timeframeIndex,
        uint margin
    ) public returns (uint id) {
        require(timeframeIndex < timeframes.length, "Invalid timeframe");
        require(margin >= minimumMargin, "Insufficient margin");

        // Calculate premium for ATM option in quote
        uint premium = calcPremium(getMarkPrice(), size, timeframes[timeframeIndex]);

        // Calculate opening fees in quote
        uint openingFees = calcFees(size / 10 ** 2);

        // Total fees in quote
        uint totalFee = premium + openingFees;

        uint swapped;

        if (isShort) {
            // base to quote
            swapped = _swapExactOut(
                address(base),
                address(quote),
                size / 10 ** 2
            );

            baseLp.lockLiquidity(swapped);
        } else {
            // quote to base
            swapped = _swapExactIn(
                address(quote),
                address(base),
                size / 10 ** 2
            );

            quoteLp.lockLiquidity(size / 10 ** 2);
        }

        // Transfer fees + margin
        quote.transferFrom(msg.sender, address(this), (totalFee + margin));

        // Transfer fees to LP
        if (isShort) {
            uint proceeds = _swapExactIn(
                address(quote),
                address(base),
                (totalFee + margin)
            );
            baseLp.addProceeds(proceeds);
        } else {
            quoteLp.addProceeds(totalFee + margin);
        }

        // Generate scalp position NFT
        id = scalpPositionMinter.mint(msg.sender);
        scalpPositions[id] = ScalpPosition({
            isOpen: true,
            isShort: isShort,
            size: size,
            amountOut: isShort ? size / 10 ** 2 : swapped,
            entry: getMarkPrice(),
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

        console.log('Closing...');

        uint swapped;
        int pnl;

        if (scalpPositions[id].isShort) {
            // quote to base
            swapped = _swapExactIn(
                address(quote),
                address(base),
                scalpPositions[id].amountOut
            );

            pnl = (int(scalpPositions[id].entry) - int(getMarkPrice())) / 10 ** 2;
            baseLp.unlockLiquidity(swapped);

            require(int(scalpPositions[id].margin) + pnl > 0, "Insufficient margin to cover negative PnL");

            _swapExactOut(
                address(base),
                address(quote),
                uint(int(scalpPositions[id].margin) + pnl)
            );
        } else {
            // base to quote
            swapped = _swapExactIn(
                address(base),
                address(quote),
                scalpPositions[id].amountOut
            );

            pnl = (int(getMarkPrice()) - int(scalpPositions[id].entry)) / 10 ** 2;
            quoteLp.unlockLiquidity(swapped);

            require(int(scalpPositions[id].margin) + pnl > 0, "Insufficient margin to cover negative PnL");
        }

        quote.transfer(msg.sender, uint(int(scalpPositions[id].margin) + pnl));

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
        uint amountIn = scalpPositions[id].amountOut;
        uint finalSize = _swapExactOut(
            address(base),
            address(quote),
            amountIn
        );

        int pnl = (int)(finalSize - scalpPositions[id].size);
        quoteLp.unlockLiquidity(scalpPositions[id].size);
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
        int pnl;
        if (scalpPositions[id].isShort) pnl = (int(scalpPositions[id].entry) - int(getMarkPrice())) / 10 ** 2;
        else pnl = (int(getMarkPrice()) - int(scalpPositions[id].entry)) / 10 ** 2;

        return int(scalpPositions[id].margin) + pnl < int(minimumAbsoluteLiquidationThreshold);
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
        uint finalSize = _swapExactOut(
            address(base),
            address(quote),
            scalpPositions[id].amountOut
        );

        int pnl = (int)(finalSize - scalpPositions[id].size);
        quoteLp.unlockLiquidity(scalpPositions[id].size);
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

    /// @notice Allow only scalp LP contract to claim collateral
    /// @param amount Amount of quote/base assets to transfer
    function claimCollateral(uint amount)
    public {
        require(msg.sender == address(quoteLp) || msg.sender == address(baseLp), "Only Scalp LP contract can claim collateral");
        if (msg.sender == address(quoteLp)) quote.transfer(msg.sender, amount);
        else if (msg.sender == address(baseLp)) base.transfer(msg.sender, amount);
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
