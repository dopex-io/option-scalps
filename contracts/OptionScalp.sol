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

contract OptionScalp is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // Base token
    IERC20 public base;
    // Quote token
    IERC20 public quote;
    // Scalp Base LP token
    ScalpLP public baseLp;
    // Scalp Quote LP token
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

    uint256[] public timeframes = [5 minutes, 15 minutes, 30 minutes];
    uint256 public expiryWindow = 60 seconds;

    // Address of multisig which handles insurance fund
    address public insuranceFund;

    // Minimum margin to open a position
    uint256 public minimumMargin = 5e6; // $5

    // Fees for opening position
    uint256 public feeOpenPosition = 5000000; // 0.05%

    // Percentage threshold above (entry - margin) when liquidate() is callable
    uint256 public liquidationThresholdPercentage = 2500000; // 0.025%

    // Minimum absolute threshold in quote asset above (entry - margin) when liquidate() is callable
    uint256 public minimumAbsoluteLiquidationThreshold = 5e6; // $5

    // Max size of a position (ie8)
    uint256 public maxSize = 100000e8; // $100k

    // Max open interest (ie6)
    uint256 public maxOpenInterest = 10000000e6; // $10M

    // Open interest (ie6)
    mapping(bool => uint256) public openInterest;

    uint256 public constant divisor = 1e8;

    // Scalp positions
    mapping(uint256 => ScalpPosition) public scalpPositions;

    struct ScalpPosition {
        // Is position open
        bool isOpen;
        // Is short
        bool isShort;
        // Total size in quote asset
        uint256 size;
        // Open position count (in base asset)
        uint256 positions;
        // Amount borrowed
        uint256 amountBorrowed;
        // Amount received from swap
        uint256 amountOut;
        // Entry price
        uint256 entry;
        // Margin provided
        uint256 margin;
        // Premium for position
        uint256 premium;
        // Fees for position
        uint256 fees;
        // Final PNL of position
        int256 pnl;
        // Opened at timestamp
        uint256 openedAt;
        // How long position is to be kept open
        uint256 timeframe;
    }

    // Deposit event
    event Deposit(bool isQuote, uint256 amount, address indexed sender);

    // Withdraw event
    event Withdraw(bool isQuote, uint256 amount, address indexed sender);

    // Open position event
    event OpenPosition(uint256 id, uint256 size, address indexed user);

    // Close position event
    event ClosePosition(uint256 id, int256 pnl, address indexed user);

    // Liquidate position event
    event LiquidatePosition(uint256 id, int256 pnl, address indexed liquidator);

    // Expire position event
    event ExpirePosition(uint256 id, int256 pnl, address indexed sender);

    constructor(
        address _base,
        address _quote,
        address _optionPricing,
        address _volatilityOracle,
        address _priceOracle,
        address _uniswapV3Router,
        address _gmxHelper,
        uint256 _minimumMargin,
        address _insuranceFund
    ) {
        require(_base != address(0), "Invalid base token");
        require(_quote != address(0), "Invalid quote token");
        require(_optionPricing != address(0), "Invalid option pricing");
        require(_volatilityOracle != address(0), "Invalid volatility oracle");
        require(_priceOracle != address(0), "Invalid price oracle");
        require(_insuranceFund != address(0), "Invalid insurance fund");

        base = IERC20(_base);
        quote = IERC20(_quote);
        optionPricing = IOptionPricing(_optionPricing);
        volatilityOracle = IVolatilityOracle(_volatilityOracle);
        priceOracle = IPriceOracle(_priceOracle);
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
        gmxHelper = IGmxHelper(_gmxHelper);
        minimumMargin = _minimumMargin;
        insuranceFund = _insuranceFund;

        scalpPositionMinter = new ScalpPositionMinter();

        base.approve(address(uniswapV3Router), type(uint256).max);
        quote.approve(address(uniswapV3Router), type(uint256).max);

        quoteLp = new ScalpLP(address(this), address(quote), quote.symbol());

        baseLp = new ScalpLP(address(this), address(base), base.symbol());

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
    ) internal returns (uint256 amountIn) {
        return
            uniswapV3Router.exactOutputSingle(
                IUniswapV3Router.ExactOutputSingleParams({
                    tokenIn: from,
                    tokenOut: to,
                    fee: 500,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountOut: amountOut,
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    /// @notice Internal function to handle swaps using Uniswap V3 exactIn
    /// @param from Address of the token to sell
    /// @param to Address of the token to buy
    /// @param amountOut Target amount of to token we want to receive
    function _swapExactIn(
        address from,
        address to,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        return
            uniswapV3Router.exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: from,
                    tokenOut: to,
                    fee: 500,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    // Deposit assets
    // @param isQuote If true user deposits quote token (else base)
    // @param amount Amount of quote asset to deposit to LP
    function deposit(bool isQuote, uint256 amount) public {
        if (isQuote) {
            quote.transferFrom(msg.sender, address(this), amount);
            quoteLp.deposit(amount, msg.sender);
        } else {
            base.transferFrom(msg.sender, address(this), amount);
            baseLp.deposit(amount, msg.sender);
        }

        emit Deposit(isQuote, amount, msg.sender);
    }

    // Withdraw
    // @param isQuote If true user withdraws quote token (else base)
    // @param amount Amount of LP positions to withdraw
    function withdraw(bool isQuote, uint256 amount) public {
        if (isQuote) {
            quoteLp.redeem(amount, msg.sender, msg.sender);
        } else {
            baseLp.redeem(amount, msg.sender, msg.sender);
        }

        emit Withdraw(isQuote, amount, msg.sender);
    }

    /// @notice Opens a position against/in favour of the base asset
    /// If you short base is swapped to quote
    function openPosition(
        bool isShort,
        uint256 size,
        uint256 timeframeIndex,
        uint256 margin
    ) public returns (uint256 id) {
        require(timeframeIndex < timeframes.length, "Invalid timeframe");
        require(margin >= minimumMargin, "Insufficient margin");
        require(size <= maxSize, "Your size is really size");
        require(
            (size / 10**2) + openInterest[isShort] <= maxOpenInterest,
            "OI is too high"
        );

        openInterest[isShort] += size / 10**2;

        uint256 markPrice = getMarkPrice();

        // Calculate premium for ATM option in quote
        uint256 premium = calcPremium(
            markPrice,
            size,
            timeframes[timeframeIndex]
        );

        console.log("Premium");
        console.log(premium);

        // Calculate opening fees in quote
        uint256 openingFees = calcFees(size / 10**2);

        // We transfer margin + premium + fees from user
        quote.transferFrom(
            msg.sender,
            address(this),
            margin + premium + openingFees
        );

        uint256 swapped;
        uint256 entry;

        if (isShort) {
            // base to quote
            swapped = _swapExactOut(
                address(base),
                address(quote),
                size / 10**2
            );

            // size is ie8, swapped is ie18
            // 1e18 * ie8 / ie18 = ie8
            entry = ((10**18) * size) / swapped;

            require(
                baseLp.totalAvailableAssets() >= swapped,
                "Insufficient liquidity"
            );

            baseLp.lockLiquidity(swapped);
        } else {
            // quote to base
            require(
                quoteLp.totalAvailableAssets() >= size / 10**2,
                "Insufficient liquidity"
            );

            swapped = _swapExactIn(address(quote), address(base), size / 10**2);

            // size is ie8, swapped is ie18
            // 1e18 * ie8 / ie18 = ie8
            entry = ((10**18) * size) / swapped;

            quoteLp.lockLiquidity(size / 10**2);
        }

        // Transfer fees to Insurance fund
        if (isShort) {
            uint256 baseOpeningFees = _swapExactIn(
                address(quote),
                address(base),
                openingFees
            );
            baseLp.deposit(baseOpeningFees, insuranceFund);

            uint256 basePremium = _swapExactIn(
                address(quote),
                address(base),
                premium
            );

            baseLp.addProceeds(basePremium);
        } else {
            quoteLp.deposit(openingFees, insuranceFund);
            quoteLp.addProceeds(premium);
        }

        // Generate scalp position NFT
        id = scalpPositionMinter.mint(msg.sender);
        scalpPositions[id] = ScalpPosition({
            isOpen: true,
            isShort: isShort,
            size: size,
            positions: (size * divisor) / entry,
            amountBorrowed: isShort ? swapped : size / 10**2,
            amountOut: isShort ? size / 10**2 : swapped,
            entry: entry,
            margin: margin,
            premium: premium,
            fees: openingFees,
            pnl: 0,
            openedAt: block.timestamp,
            timeframe: timeframes[timeframeIndex]
        });

        emit OpenPosition(id, size, msg.sender);
    }

    /// @notice Closes an open position
    /// @param id ID of position
    function closePosition(uint256 id) public {
        require(scalpPositions[id].isOpen, "Invalid position ID");

        if (IERC721(scalpPositionMinter).ownerOf(id) == msg.sender) {
            require(
                block.timestamp <=
                    scalpPositions[id].openedAt + scalpPositions[id].timeframe,
                "The owner must close position before expiry"
            );
        } else {
            if (!isLiquidatable(id))
                require(
                    block.timestamp + expiryWindow >=
                        scalpPositions[id].openedAt + scalpPositions[id].timeframe,
                    "Keeper can only close from an window before expiry"
                );
        }

        uint256 swapped;
        uint256 price;
        uint256 traderWithdraw;

        if (scalpPositions[id].isShort) {
            // quote to base
            swapped = _swapExactIn(
                address(quote),
                address(base),
                scalpPositions[id].amountOut + scalpPositions[id].margin
            );

            if (swapped > scalpPositions[id].amountBorrowed) {
                baseLp.unlockLiquidity(scalpPositions[id].amountBorrowed);

                //convert remaining base to quote to pay for trader
                traderWithdraw = _swapExactIn(
                    address(base),
                    address(quote),
                    swapped - scalpPositions[id].amountBorrowed
                );

                quote.transfer(
                    isLiquidatable(id) ? insuranceFund : IERC721(scalpPositionMinter).ownerOf(id),
                    traderWithdraw
                );
            } else {
                baseLp.unlockLiquidity(swapped);
            }
        } else {
            // base to quote
            swapped = _swapExactIn(
                address(base),
                address(quote),
                scalpPositions[id].amountOut
            );

            if (
                scalpPositions[id].margin + swapped >
                scalpPositions[id].amountBorrowed
            ) {
                quoteLp.unlockLiquidity(scalpPositions[id].amountBorrowed);

                traderWithdraw =
                    scalpPositions[id].margin +
                    swapped -
                    scalpPositions[id].amountBorrowed;

                quote.transfer(
                    isLiquidatable(id) ? insuranceFund : IERC721(scalpPositionMinter).ownerOf(id),
                    traderWithdraw
                );
            } else {
                quoteLp.unlockLiquidity(scalpPositions[id].margin + swapped);
            }
        }

        openInterest[scalpPositions[id].isShort] -=
            scalpPositions[id].size /
            10**2;
        scalpPositions[id].isOpen = false;

        emit ClosePosition(id, int256(traderWithdraw), msg.sender);
    }

    /// @notice Returns whether an open position is liquidatable
    function isLiquidatable(uint256 id) public view returns (bool) {

        console.log("MARGIN");
        console.log(scalpPositions[id].margin);
        console.log("PNL");
        console.logInt(calcPnl(id));
        console.log("MINIMUM");
        console.logInt((int256(minimumAbsoluteLiquidationThreshold) *
                int256(scalpPositions[id].positions)) /
                10**8);

        bool flag =
            int256(scalpPositions[id].margin) + calcPnl(id) <=
            (int256(minimumAbsoluteLiquidationThreshold) *
                int256(scalpPositions[id].positions)) /
                10**8;

        console.log("IS LIQUIDATABLE?");
        console.log(flag);

        return flag;
    }

    /// @notice Allow only scalp LP contract to claim collateral
    /// @param amount Amount of quote/base assets to transfer
    function claimCollateral(uint256 amount) public {
        require(
            msg.sender == address(quoteLp) || msg.sender == address(baseLp),
            "Only Scalp LP contract can claim collateral"
        );
        if (msg.sender == address(quoteLp)) quote.transfer(msg.sender, amount);
        else if (msg.sender == address(baseLp))
            base.transfer(msg.sender, amount);
    }

    /// @notice External function to return the volatility
    /// @param strike Strike of option
    function getVolatility(uint256 strike)
        public
        view
        returns (uint256 volatility)
    {
        volatility = uint256(volatilityOracle.getVolatility(strike));
    }

    /// @notice Internal function to calculate premium
    /// @param strike Strike of option
    /// @param size Amount of option
    function calcPremium(
        uint256 strike,
        uint256 size,
        uint256 timeToExpiry
    ) internal view returns (uint256 premium) {
        uint256 expiry = block.timestamp + timeToExpiry;
        premium = ((uint256(
            optionPricing.getOptionPrice(
                false,
                expiry,
                strike,
                strike,
                getVolatility(strike)
            )
        ) * size) / strike); // ATM options: does not matter if call or put

        premium = premium / (divisor / uint256(10**quote.decimals()));
    }

    /// @notice Internal function to calculate fees
    /// @param amount Value of option in USD (ie6)
    function calcFees(uint256 amount) internal view returns (uint256 fees) {
        fees = (amount * feeOpenPosition) / (100 * divisor);
    }

    /// @notice Internal function to calculate pnl
    /// @param id ID of position
    function calcPnl(uint256 id) internal view returns (int256 pnl) {
        uint256 markPrice = getMarkPrice();

        console.log("MARK PRICE");
        console.log(markPrice);

        console.log("ENTRY");
        console.logInt(int256(scalpPositions[id].entry));

        console.log("POSITIONS");
        console.log(scalpPositions[id].positions);

        // positions is ie8
        // entry is ie8
        // markPrice is ie8
        // pnl is ie6

        if (scalpPositions[id].isShort)
            pnl =
                (int256(scalpPositions[id].positions) *
                    (int256(scalpPositions[id].entry) - int256(markPrice))) /
                10**10;
        else
            pnl =
                (int256(scalpPositions[id].positions) *
                    (int256(markPrice) - int256(scalpPositions[id].entry))) /
                10**10;

        console.log("PNL");
        console.logInt(pnl);
    }

    /// @notice Internal function to calculate actual pnl
    /// @param id ID of position
    /// @param pnl computed using actual price ie6
    function calcActualPnl(uint256 id, uint256 actualPrice)
        internal
        view
        returns (int256 pnl)
    {
        if (scalpPositions[id].isShort)
            pnl =
                (int256(scalpPositions[id].positions) *
                    (int256(scalpPositions[id].entry) - int256(actualPrice))) /
                10**10;
        else
            pnl =
                (int256(scalpPositions[id].positions) *
                    (int256(actualPrice) - int256(scalpPositions[id].entry))) /
                10**10;
    }

    /// @notice Public function to retrieve price of base asset from oracle
    /// @param price Mark price
    function getMarkPrice() public view returns (uint256 price) {
        price = uint256(priceOracle.getUnderlyingPrice());
    }

    function checkMath() public view {
        console.log("QUOTE");
        console.log(quote.balanceOf(address(this)));
        console.log("QUOTE TOTAL ASSETS");
        console.log(quoteLp.totalAssets());
        console.log("QUOTE TOTAL AVAILABLE ASSETS");
        console.log(quoteLp.totalAvailableAssets());

        console.log("BASE");
        console.log(base.balanceOf(address(this)));
        console.log("BASE TOTAL ASSETS");
        console.log(baseLp.totalAssets());
        console.log("BASE TOTAL AVAILABLE ASSETS");
        console.log(baseLp.totalAvailableAssets());
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }
}