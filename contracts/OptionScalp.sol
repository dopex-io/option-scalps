// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IERC20} from "./interface/IERC20.sol";
import {INonfungiblePositionManager} from "./interface/INonfungiblePositionManager.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {ContractWhitelist} from "./helpers/ContractWhitelist.sol";

import {ScalpLP} from "./token/ScalpLP.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {ScalpPositionMinter} from "./positions/ScalpPositionMinter.sol";
import {LimitOrderManager} from "./LimitOrderManager.sol";

import {Pausable} from "./helpers/Pausable.sol";

import {IOptionPricing} from "./interface/IOptionPricing.sol";
import {IVolatilityOracle} from "./interface/IVolatilityOracle.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {IUniswapV3Router} from "./interface/IUniswapV3Router.sol";
import {IUniswapV3Pool} from "./interface/IUniswapV3Pool.sol";

contract OptionScalp is Ownable, Pausable, ReentrancyGuard, ContractWhitelist, ERC721Holder {
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

    // NonfungiblePositionManager
    INonfungiblePositionManager nonFungiblePositionManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    uint256[] public timeframes = [
        1 minutes,
        5 minutes,
        15 minutes,
        30 minutes,
        60 minutes
    ];

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

    // Cumulative pnl (quoteDecimals)
    mapping(address => int256) public cumulativePnl;

    // Cumulative volume (quoteDecimals)
    mapping(address => uint256) public cumulativeVolume;

    // Withdraw timeout
    uint256 public withdrawTimeout;

    // Scalp positions
    mapping(uint256 => ScalpPosition) public scalpPositions;

    // Limit orders manager
    LimitOrderManager public limitOrderManager;

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
        // seconds to wait before withdraw
        uint256 withdrawTimeout;
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

    // Shortfall
    event Shortfall(bool isQuote, uint256 amount);

    // AddProceeds event
    event AddProceeds(bool isQuote, uint256 amount);

    // Emergency withdraw
    event EmergencyWithdraw(address indexed receiver);

    constructor(
        address _base,
        address _quote,
        uint256 _baseDecimals,
        uint256 _quoteDecimals,
        address _uniswapV3Router,
        address _limitOrdersManager,
        Configuration memory config
    ) {
        require(_base != address(0), "Invalid base token");
        require(_quote != address(0), "Invalid quote token");

        base = IERC20(_base);
        quote = IERC20(_quote);
        baseDecimals = _baseDecimals;
        quoteDecimals = _quoteDecimals;
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
        limitOrderManager = LimitOrderManager(_limitOrdersManager);

        maxSize = config.maxSize;
        maxOpenInterest = config.maxOpenInterest;
        optionPricing = config.optionPricing;
        volatilityOracle = config.volatilityOracle;
        priceOracle = config.priceOracle;
        insuranceFund = config.insuranceFund;
        minimumMargin = config.minimumMargin;
        feeOpenPosition = config.feeOpenPosition;
        minimumAbsoluteLiquidationThreshold = config
            .minimumAbsoluteLiquidationThreshold;
        withdrawTimeout = config.withdrawTimeout;

        scalpPositionMinter = new ScalpPositionMinter();

        base.approve(address(uniswapV3Router), type(uint256).max);
        quote.approve(address(uniswapV3Router), type(uint256).max);

        base.approve(_limitOrdersManager, type(uint256).max);
        quote.approve(_limitOrdersManager, type(uint256).max);

        quoteLp = new ScalpLP(address(this), _limitOrdersManager, address(quote), quote.symbol());

        baseLp = new ScalpLP(address(this), _limitOrdersManager, address(base), base.symbol());

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
    function deposit(
        address receiver,
        bool isQuote,
        uint256 amount
    ) public nonReentrant returns (uint256 shares) {
        _isEligibleSender();

        if (isQuote) {
            quote.safeTransferFrom(msg.sender, address(this), amount);
            shares = quoteLp.deposit(amount, receiver);
        } else {
            base.safeTransferFrom(msg.sender, address(this), amount);
            shares = baseLp.deposit(amount, receiver);
        }

        emit Deposit(isQuote, amount, msg.sender);
    }

    // Withdraw
    // @param isQuote If true user withdraws quote token (else base)
    // @param amount Amount of LP positions to withdraw
    function withdraw(
        bool isQuote,
        uint256 amount
    ) public returns (uint256 assets) {
        _isEligibleSender();

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
    ) public nonReentrant returns (uint256 id, uint256 entry) {
        _isEligibleSender();

        require(timeframeIndex < timeframes.length, "Invalid timeframe");
        require(margin >= minimumMargin, "Insufficient margin");
        require(size <= maxSize, "Position exposure is too high");
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

        // Calculate opening fees in quote
        uint256 openingFees = calcFees(size);

        // We transfer margin + premium + fees from user
        quote.safeTransferFrom(
            msg.sender,
            address(this),
            margin + premium + openingFees
        );

        uint256 swapped;

        if (isShort) {
            // base to quote
            swapped = _swapExactOut(address(base), address(quote), size);

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
            emit AddProceeds(false, basePremium);
        } else {
            quoteLp.deposit(openingFees, insuranceFund);
            quoteLp.addProceeds(premium);
            emit AddProceeds(true, premium);
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
        _isEligibleSender();

        require(scalpPositions[id].isOpen, "Invalid position ID");
        require(
            scalpPositions[id].openedAt + 1 seconds <= block.timestamp,
            "Position must be open for at least 1 second"
        );

        address owner = IERC721(scalpPositionMinter).ownerOf(id);

        if (!isLiquidatable(id) && msg.sender != owner)
            require(
                block.timestamp >=
                    scalpPositions[id].openedAt + scalpPositions[id].timeframe,
                "Keeper can only close after expiry"
            );

        uint256 swapped;
        uint256 traderWithdraw;

        scalpPositions[id].isOpen = false;
        scalpPositionMinter.burn(id);

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

                quote.safeTransfer(
                    isLiquidatable(id) ? insuranceFund : owner,
                    traderWithdraw
                );
            } else {
                baseLp.unlockLiquidity(swapped);
                emit Shortfall(false, scalpPositions[id].amountBorrowed - swapped);
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

                quote.safeTransfer(
                    isLiquidatable(id) ? insuranceFund : owner,
                    traderWithdraw
                );
            } else {
                quoteLp.unlockLiquidity(scalpPositions[id].margin + swapped);
                emit Shortfall(true, scalpPositions[id].amountBorrowed - scalpPositions[id].margin + swapped);
            }
        }

        openInterest[scalpPositions[id].isShort] -= scalpPositions[id].size;
        int256 pnl = int256(traderWithdraw) - int256(scalpPositions[id].margin + scalpPositions[id].premium + scalpPositions[id].fees);
        scalpPositions[id].pnl = pnl;
        cumulativePnl[owner] += pnl;
        cumulativeVolume[owner] += scalpPositions[id].size;

        emit ClosePosition(id, pnl, msg.sender);
    }

    /// @notice Returns whether an open position is liquidatable
    function isLiquidatable(uint256 id) public view returns (bool) {
        return
            int256(scalpPositions[id].margin) + calcPnl(id) <=
            int256(
                minimumAbsoluteLiquidationThreshold *
                    (scalpPositions[id].size / (10 ** quoteDecimals))
            );
    }

    /// @notice Get liquidation price
    /// @param id Identifier of the position
    function getLiquidationPrice(
        uint256 id
    ) public view returns (uint256 price) {
        if(!scalpPositions[id].isOpen) return 0;

        int256 threshold = int256(scalpPositions[id].margin) -
            int256(
                (minimumAbsoluteLiquidationThreshold *
                    scalpPositions[id].size) / (10 ** quoteDecimals)
            );

        if (scalpPositions[id].isShort) {
            price =
                scalpPositions[id].entry +
                (((10 ** quoteDecimals) * uint(threshold)) /
                    scalpPositions[id].size); // (quoteDecimals)
        } else {
            price =
                scalpPositions[id].entry -
                (((10 ** quoteDecimals) * uint(threshold)) /
                    scalpPositions[id].size); // (quoteDecimals)
        }
    }

    /// @notice Allow only scalp LP contract to claim collateral
    /// @param amount Amount of quote/base assets to transfer
    function claimCollateral(uint256 amount) public nonReentrant {
        require(
            msg.sender == address(quoteLp) || msg.sender == address(baseLp),
            "Only Scalp LP contract can claim collateral"
        );
        if (msg.sender == address(quoteLp))
            quote.safeTransfer(msg.sender, amount);
        else if (msg.sender == address(baseLp))
            base.safeTransfer(msg.sender, amount);
    }

    /// @notice External function to return the volatility
    /// @param strike Strike of option
    function getVolatility(
        uint256 strike
    ) public view returns (uint256 volatility) {
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
                int256(10 ** quoteDecimals);
        else
            pnl =
                (int256(scalpPositions[id].positions) *
                    (int256(markPrice) - int256(scalpPositions[id].entry))) /
                int256(10 ** quoteDecimals);
    }

    function mintUniswapV3Position(address token0, address token1, int24 tick0, int24 tick1, uint256 amount0, uint256 amount1) public returns (uint256 positionId) {
      require(msg.sender == address(limitOrderManager), "Wrong sender");

      nonFungiblePositionManager.mint(INonfungiblePositionManager.MintParams(
        token0, token1, 500, tick0, tick1, 0, amount0, amount1, 0, address(this), block.timestamp
      ));
      positionId = nonFungiblePositionManager.tokenOfOwnerByIndex(address(this), nonFungiblePositionManager.balanceOf(address(this)) - 1);
    }

    function burnUniswapV3Position(IUniswapV3Pool pool, uint256 positionId, bool isShort) public returns (uint256 swapped) {
        require(msg.sender == address(limitOrderManager));

        (,,,,,,,uint128 liquidity,,,,) = nonFungiblePositionManager.positions(positionId);
        (uint256 amount0, uint256 amount1) = nonFungiblePositionManager.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams(positionId, liquidity, 0, 0, block.timestamp));

        address token0 = pool.token0();
        address token1 = pool.token1();

        if (address(base) == token0) {
          // amount0 is base
          // amount1 is quote
          if (isShort) swapped = amount1;
          else swapped = amount0;
        }  else {
          // amount0 is quote
          // amount1 is base
          if (isShort) swapped = amount0;
          else swapped = amount1;
        }
    }

    function openPositionFromLimitOrder(uint256 swapped, bool isShort, uint256 collateral, uint256 size, uint256 timeframeIndex, uint256 lockedLiquidity) public returns (uint256 id) {
      require(msg.sender == address(limitOrderManager));

      uint256 entry = ((10 ** baseDecimals) * size) / swapped;

      uint256 markPrice = getMarkPrice();

      // Calculate premium for ATM option in quote
      uint256 premium = calcPremium(
          markPrice,
          size,
          timeframes[timeframeIndex]
      );

      // Calculate opening fees in quote
      uint256 openingFees = calcFees(size);

      require(collateral > premium + openingFees, "Insufficient margin");

      // Generate scalp position NFT
      id = scalpPositionMinter.mint(msg.sender);
      scalpPositions[id] = ScalpPosition({
            isOpen: true,
            isShort: isShort,
            size: size,
            positions: (size * (10 ** quoteDecimals)) / entry,
            amountBorrowed: lockedLiquidity,
            amountOut: swapped,
            entry: entry,
            margin: collateral - premium - openingFees,
            premium: premium,
            fees: openingFees,
            pnl: 0,
            openedAt: block.timestamp,
            timeframe: timeframes[timeframeIndex]
      });

      emit OpenPosition(id, size, msg.sender);
    }

    /// @notice Public function to retrieve price of base asset from oracle
    /// @param price Mark price (quoteDecimals)
    function getMarkPrice() public view returns (uint256 price) {
        price = uint256(priceOracle.getUnderlyingPrice()) / 10 ** 2;
    }

    /// @notice Returns the tokenIds owned by a wallet
    /// @param owner wallet owner
    function positionsOfOwner(
        address owner
    ) public view returns (uint256[] memory tokenIds) {
        uint256 ownerTokenCount = scalpPositionMinter.balanceOf(owner);

        tokenIds = new uint256[](ownerTokenCount);
        uint256 start;
        uint256 idx;

        while (start < ownerTokenCount) {
            uint256 tokenId = scalpPositionMinter.tokenOfOwnerByIndex(
                owner,
                idx
            );
            tokenIds[start] = tokenId;
            ++start;
            ++idx;
        }
    }

    /// @notice Owner-only function to update config
    /// @param config Valid configuration struct
    function updateConfig(Configuration calldata config) public onlyOwner {
        maxSize = config.maxSize;
        maxOpenInterest = config.maxOpenInterest;
        optionPricing = config.optionPricing;
        volatilityOracle = config.volatilityOracle;
        priceOracle = config.priceOracle;
        insuranceFund = config.insuranceFund;
        minimumMargin = config.minimumMargin;
        feeOpenPosition = config.feeOpenPosition;
        minimumAbsoluteLiquidationThreshold = config
            .minimumAbsoluteLiquidationThreshold;
        withdrawTimeout = config.withdrawTimeout;
    }

    /// @notice Transfers all funds to msg.sender
    /// @dev Can only be called by the owner
    /// @param tokens The list of erc20 tokens to withdraw
    /// @param transferNative Whether should transfer the native currency
    function emergencyWithdraw(
        address[] calldata tokens,
        bool transferNative
    ) external onlyOwner {
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

    /**
     * @notice Add a contract to the whitelist
     * @dev    Can only be called by the owner
     * @param _contract Address of the contract that needs to be added to the whitelist
     */
    function addToContractWhitelist(address _contract) external onlyOwner {
        _addToContractWhitelist(_contract);
    }

    /**
     * @notice Add a contract to the whitelist
     * @dev    Can only be called by the owner
     * @param _contract Address of the contract that needs to be added to the whitelist
     */
    function removeFromContractWhitelist(address _contract) external onlyOwner {
        _removeFromContractWhitelist(_contract);
    }
}
