// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Libraries
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "../interface/IUniswapV2Router02.sol";
import {IUniswapV3Router} from "../interface/IUniswapV3Router.sol";
import {IGmxRouter} from "../interface/IGmxRouter.sol";

// Contracts
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Swaps tokens on different AMMs
/// @author Dopex
contract AssetSwapper is Ownable {
    using SafeERC20 for IERC20;

    /// @dev Uniswap V2 SwapRouter
    IUniswapV2Router02 public uniV2Router;

    /// @dev Uniswap V3 SwapRouter
    IUniswapV3Router public uniV3Router;

    /// @dev Gmx SwapRouter
    IGmxRouter public gmxRouter;

    /// @dev weth address
    address public immutable weth;

    event SetUniV2RouterAddress(address indexed swapper);
    event SetUniV3RouterAddress(address indexed swapper);
    event SetGmxRouterAddress(address indexed swapper);

    event Swap(
        uint256 indexed swapperId,
        address from,
        address to,
        uint256 amount,
        uint256 amountOut
    );

    constructor(
        address _uniV2Router,
        address _uniV3Router,
        address _gmxRouter,
        address _weth
    ) {
        require(
            _uniV2Router != address(0) &&
                _uniV3Router != address(0) &&
                _gmxRouter != address(0),
            "Router address cannot be 0 address"
        );
        require(_weth != address(0), "WETH address cannot be 0 address");
        uniV2Router = IUniswapV2Router02(_uniV2Router);
        uniV3Router = IUniswapV3Router(_uniV3Router);
        gmxRouter = IGmxRouter(_gmxRouter);
        weth = _weth;

        emit SetUniV2RouterAddress(_uniV2Router);
        emit SetUniV3RouterAddress(_uniV3Router);
        emit SetGmxRouterAddress(_gmxRouter);
    }

    function setUniV2RouterAddress(address _address)
        external
        onlyOwner
        returns (bool)
    {
        require(_address != address(0), "address cannot be null");

        uniV2Router = IUniswapV2Router02(_address);

        emit SetUniV2RouterAddress(_address);

        return true;
    }

    function setUniV3RouterAddress(address _address)
        external
        onlyOwner
        returns (bool)
    {
        require(_address != address(0), "address cannot be null");

        uniV3Router = IUniswapV3Router(_address);

        emit SetUniV3RouterAddress(_address);

        return true;
    }

    function setGmxRouterAddress(address _address)
        external
        onlyOwner
        returns (bool)
    {
        require(_address != address(0), "address cannot be null");

        gmxRouter = IGmxRouter(_address);

        emit SetGmxRouterAddress(_address);

        return true;
    }

    function _swapUsingUniV2(
        address from,
        address to,
        uint256 amount,
        uint256 minAmountOut
    ) internal returns (uint256) {
        address[] memory path;

        if (from == weth || to == weth) {
            path = new address[](2);
            path[0] = from;
            path[1] = to;
        } else {
            path = new address[](3);
            path[0] = from;
            path[1] = weth;
            path[2] = to;
        }

        IERC20(from).safeApprove(address(uniV2Router), amount);

        uint256 amountOut = uniV2Router.swapExactTokensForTokens(
            amount,
            minAmountOut,
            path,
            address(this),
            block.timestamp
        )[path.length - 1];

        return amountOut;
    }

    function _swapUsingUniV3(
        address from,
        address to,
        uint256 amount,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        IERC20(from).safeApprove(address(uniV3Router), amount);

        IUniswapV3Router.ExactInputSingleParams
            memory swapParams = IUniswapV3Router.ExactInputSingleParams(
                from,
                to,
                500,
                address(this),
                block.timestamp,
                amount,
                minAmountOut,
                0
            );

        amountOut = uniV3Router.exactInputSingle(swapParams);
    }

    function _swapUsingGmx(
        address from,
        address to,
        uint256 amount,
        uint256 minAmountOut
    ) internal returns (uint256) {
        IERC20(from).safeApprove(address(gmxRouter), amount);

        uint256 initialAmountOut = IERC20(to).balanceOf(address(this));

        address[] memory path;

        path = new address[](2);
        path[0] = from;
        path[1] = to;

        gmxRouter.swap(path, amount, minAmountOut, address(this));

        uint256 amountOut = IERC20(to).balanceOf(address(this)) -
            initialAmountOut;

        return amountOut;
    }

    /// @dev Swaps between given `from` and `to` assets
    /// @param from From token address
    /// @param to To token address
    /// @param amount From token amount
    /// @param minAmountOut Minimum token amount to receive out
    /// @return tokenOut token amount received
    function swapAsset(
        address from,
        address to,
        uint256 amount,
        uint256 minAmountOut,
        uint256 swapperId
    ) external returns (uint256) {
        IERC20(from).safeTransferFrom(msg.sender, address(this), amount);

        uint256 amountOut = 0;

        if (swapperId == 0) {
            amountOut = _swapUsingUniV2(from, to, amount, minAmountOut);
        } else if (swapperId == 1) {
            amountOut = _swapUsingUniV3(from, to, amount, minAmountOut);
        } else if (swapperId == 2) {
            amountOut = _swapUsingGmx(from, to, amount, minAmountOut);
        } else if (swapperId == 3) {
            // use sushi to ETH then gmx
            amountOut = _swapUsingGmx(
                weth,
                to,
                _swapUsingUniV2(from, weth, amount, 0),
                minAmountOut
            );
        } else if (swapperId == 4) {
            // use sushi to ETH then uni v3
            amountOut = _swapUsingUniV3(
                weth,
                to,
                _swapUsingUniV2(from, weth, amount, 0),
                minAmountOut
            );
        } else if (swapperId == 5) {
            // use gmx to ETH then sushi
            amountOut = _swapUsingUniV2(
                weth,
                to,
                _swapUsingGmx(from, weth, amount, 0),
                minAmountOut
            );
        } else if (swapperId == 6) {
            // use uni v3 to ETH then sushi
            amountOut = _swapUsingUniV2(
                weth,
                to,
                _swapUsingUniV3(from, weth, amount, 0),
                minAmountOut
            );
        } else {
            revert("Swapper Id Incorrect");
        }

        emit Swap(swapperId, from, to, amount, amountOut);

        IERC20(to).safeTransfer(msg.sender, amountOut);
        return amountOut;
    }
}
