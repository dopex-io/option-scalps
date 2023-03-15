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
    // Base decimals
    uint256 public baseDecimals;
    // Quote decimals
    uint256 public quoteDecimals;
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

    uint256[] public timeframes = [1 minutes, 5 minutes, 15 minutes, 30 minutes, 60 minutes];

    // Address of multisig which handles insurance fund
    address public insuranceFund;

    // Minimum margin to open a position (quoteDecimals)
    uint256 public minimumMargin;

    // Fees for opening position (divisor)
    uint256 public feeOpenPosition;

    // Minimum absolute threshold in quote asset above (entry - margin) when liquidate() is callable
    uint256 public minimumAbsoluteLiquidationThreshold;

    // Max size of a position (quoteDecimals)
    uint256 public maxSize;

    // Max open interest (quoteDecimals)
    uint256 public maxOpenInterest;

    // Used for percentages
    uint256 public constant divisor = 1e8;

    // Open interest (quoteDecimals)
    mapping(bool => uint256) public openInterest;

    // Scalp positions
    mapping(uint256 => ScalpPosition) public scalpPositions;

    struct Configuration {
        // quoteDecimals Max size of a position
        uint256 maxSize;
        // quoteDecimals Max open interest
        uint256 maxOpenInterest;
        IOptionPricing optionPricing;
        IVolatilityOracle volatilityOracle;
        IPriceOracle priceOracle;
        // Address receiving liquidation fees
        address insuranceFund;
        // quoteDecimals Minimum margin to open a position
        uint256 minimumMargin;
        // divisor Fees for opening position
        uint256 feeOpenPosition;
        // quoteDecimals Min. Abs. Thres. to liquidate
        uint256 minimumAbsoluteLiquidationThreshold;
    }

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

    // Emergency withdraw
    event EmergencyWithdraw(address indexed receiver);

    constructor(
        address _base,
        address _quote,
        uint256 _baseDecimals,
        uint256 _quoteDecimals,
        address _uniswapV3Router,
        address _gmxHelper,
        Configuration memory config
    ) {
        require(_base != address(0), "Invalid base token");
        require(_quote != address(0), "Invalid quote token");

        base = IERC20(_base);
        quote = IERC20(_quote);
        baseDecimals = _baseDecimals;
        quoteDecimals = _quoteDecimals;
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
        gmxHelper = IGmxHelper(_gmxHelper);

        maxSize = config.maxSize;
        maxOpenInterest = config.maxOpenInterest;
        optionPricing = config.optionPricing;
        volatilityOracle = config.volatilityOracle;
        priceOracle = config.priceOracle;
        insuranceFund = config.insuranceFund;
        minimumMargin = config.minimumMargin;
        feeOpenPosition = config.feeOpenPosition;
        minimumAbsoluteLiquidationThreshold = config.minimumAbsoluteLiquidationThreshold;

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
    function deposit(bool isQuote, uint256 amount) public returns (uint256 shares) {
        if (isQuote) {
            quote.transferFrom(msg.sender, address(this), amount);
            shares = quoteLp.deposit(amount, msg.sender);
        } else {
            base.transferFrom(msg.sender, address(this), amount);
            shares = baseLp.deposit(amount, msg.sender);
        }

        emit Deposit(isQuote, amount, msg.sender);
    }

    // Withdraw
    // @param isQuote If true user withdraws quote token (else base)
    // @param amount Amount of LP positions to withdraw
    function withdraw(bool isQuote, uint256 amount) public returns (uint256 assets) {
        if (isQuote) {
            assets = quoteLp.redeem(amount, msg.sender, msg.sender);
        } else {
            assets = baseLp.redeem(amount, msg.sender, msg.sender);
        }

        emit Withdraw(isQuote, amount, msg.sender);

        return assets;
    }

    /// @notice Opens a position against/in favour of the base asset (if you short base is swapped to quote)
    /// @param size Size of position (quoteDecimals)
    /// @param timeframeIndex Position of the array
    /// @param margin Collateral posted by user
    /// @param entryLimit Minimum or maximum entry price (for short or long)
    function openPosition(
        bool isShort,
        uint256 size,
        uint256 timeframeIndex,
        uint256 margin,
        uint256 entryLimit
    ) public returns (uint256 id, uint256 entry) {
        require(timeframeIndex < timeframes.length, "Invalid timeframe");
        require(margin >= minimumMargin, "Insufficient margin");
        require(size <= maxSize, "Your size is too big");
        require(
            size + openInterest[isShort] <= maxOpenInterest,
            "OI is too high"
        );

        openInterest[isShort] += size;

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
        uint256 openingFees = calcFees(size);

        console.log("Fees");
        console.log(openingFees);

        // We transfer margin + premium + fees from user
        quote.transferFrom(
            msg.sender,
            address(this),
            margin + premium + openingFees
        );

        uint256 swapped;

        if (isShort) {
            // base to quote
            swapped = _swapExactOut(
                address(base),
                address(quote),
                size
            );

            // size is quoteDecimals, swapped is baseDecimals
            // baseDecimals * quoteDecimals / (baseDecimals) = quoteDecimals
            entry = ((10 ** baseDecimals) * size) / swapped;

            require(entry >= entryLimit, "Slippage");

            require(
                baseLp.totalAvailableAssets() >= swapped,
                "Insufficient liquidity"
            );

            baseLp.lockLiquidity(swapped);
        } else {
            // quote to base
            require(
                quoteLp.totalAvailableAssets() >= size,
                "Insufficient liquidity"
            );

            swapped = _swapExactIn(address(quote), address(base), size);

            // size is quoteDecimals, swapped is baseDecimals
            // baseDecimals * quoteDecimals / baseDecimals = quoteDecimals
            entry = ((10 ** baseDecimals) * size) / swapped;

            require(entry <= entryLimit, "Slippage");

            quoteLp.lockLiquidity(size);
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
            positions: (size * (10 ** quoteDecimals)) / entry,
            amountBorrowed: isShort ? swapped : size,
            amountOut: isShort ? size : swapped,
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
        require(scalpPositions[id].openedAt + 1 seconds <= block.timestamp,
            "Position must be open for at least 1 second"
        );

        if (!isLiquidatable(id) && msg.sender != IERC721(scalpPositionMinter).ownerOf(id))
            require(
                block.timestamp >=
                    scalpPositions[id].openedAt + scalpPositions[id].timeframe,
                "Keeper can only close after expiry"
            );

        uint256 swapped;
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

        openInterest[scalpPositions[id].isShort] -= scalpPositions[id].size;
        scalpPositions[id].isOpen = false;

        emit ClosePosition(id, int256(traderWithdraw), msg.sender);
    }

    /// @notice Returns whether an open position is liquidatable
    function isLiquidatable(uint256 id) public view returns (bool) {
        console.log("Margin");
        console.log(scalpPositions[id].margin);
        console.log("PNL");
        console.logInt(calcPnl(id));

        return int256(scalpPositions[id].margin) + calcPnl(id) <=
            int256(minimumAbsoluteLiquidationThreshold *
                (scalpPositions[id].positions / (10 ** quoteDecimals)));
    }

    /// @notice Get liquidation price
    /// @param id Identifier of the position
    function getLiquidationPrice(uint256 id) public view returns (uint256 price) {
        int256 threshold = int256(scalpPositions[id].margin) - int256(minimumAbsoluteLiquidationThreshold * scalpPositions[id].positions / (10 ** quoteDecimals));

        if (scalpPositions[id].isShort) {
          price = scalpPositions[id].entry + ((10 ** quoteDecimals) * uint(threshold) / scalpPositions[id].positions); // (quoteDecimals)
        } else {
          price = scalpPositions[id].entry - ((10 ** quoteDecimals) * uint(threshold) / scalpPositions[id].positions); // (quoteDecimals)
        }
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
    ) public view returns (uint256 premium) {
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
    }

    /// @notice Internal function to calculate fees
    /// @param amount Value of option in USD (ie6)
    function calcFees(uint256 amount) public view returns (uint256 fees) {
        fees = (amount * feeOpenPosition) / (100 * divisor);
    }

    /// @notice Internal function to calculate pnl
    /// @param id ID of position
    /// @dev positions is quoteDecimals, entry is quoteDecimals, markPrice is quoteDecimals, pnl is quoteDecimals
    function calcPnl(uint256 id) public view returns (int256 pnl) {
        uint256 markPrice = getMarkPrice();

        if (scalpPositions[id].isShort)
            pnl =
                (int256(scalpPositions[id].positions) *
                    (int256(scalpPositions[id].entry) - int256(markPrice))) /
                10**6;
        else
            pnl =
                (int256(scalpPositions[id].positions) *
                    (int256(markPrice) - int256(scalpPositions[id].entry))) /
                10**6;
    }

    /// @notice Public function to retrieve price of base asset from oracle
    /// @param price Mark price (quoteDecimals)
    function getMarkPrice() public view returns (uint256 price) {
        price = uint256(priceOracle.getUnderlyingPrice()) / 10 ** 2;
    }

    /// @notice Returns the tokenIds owned by a wallet
    /// @param owner wallet owner
    function positionsOfOwner(address owner)
        public
        view
        returns (uint256[] memory tokenIds)
    {
      uint256 ownerTokenCount = scalpPositionMinter.balanceOf(owner);

      tokenIds = new uint256[](ownerTokenCount);
      uint256 start;
      uint256 idx;

      while (start < ownerTokenCount) {
          uint256 tokenId = scalpPositionMinter.tokenOfOwnerByIndex(owner, idx);
          tokenIds[start] = tokenId;
          ++start;
          ++idx;
      }
    }

    /// @notice Owner-only function to update config
    /// @param config Valid configuration struct
    function updateConfig(Configuration calldata config) onlyOwner public {
        maxSize = config.maxSize;
        maxOpenInterest = config.maxOpenInterest;
        optionPricing = config.optionPricing;
        volatilityOracle = config.volatilityOracle;
        priceOracle = config.priceOracle;
        insuranceFund = config.insuranceFund;
        minimumMargin = config.minimumMargin;
        feeOpenPosition = config.feeOpenPosition;
        minimumAbsoluteLiquidationThreshold = config.minimumAbsoluteLiquidationThreshold;
    }

    /// @notice Transfers all funds to msg.sender
    /// @dev Can only be called by the owner
    /// @param tokens The list of erc20 tokens to withdraw
    /// @param transferNative Whether should transfer the native currency
    function emergencyWithdraw(address[] calldata tokens, bool transferNative) external onlyOwner {
        if (transferNative) payable(msg.sender).transfer(address(this).balance);

        IERC20 token;

        for (uint256 i; i < tokens.length; ) {
            token = IERC20(tokens[i]);
            token.safeTransfer(msg.sender, token.balanceOf(address(this)));

            unchecked {
                ++i;
            }
        }

        emit EmergencyWithdraw(msg.sender);
    }
}