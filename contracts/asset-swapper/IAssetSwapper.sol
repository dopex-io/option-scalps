// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

interface IAssetSwapper {
    function swapAsset(
        address from,
        address to,
        uint256 amount,
        uint256 minAmountOut,
        uint256 swapperId
    ) external returns (uint256);
}
