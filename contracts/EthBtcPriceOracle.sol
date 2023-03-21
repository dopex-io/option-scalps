// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Interfaces
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {FlagsInterface} from "@chainlink/contracts/src/v0.8/interfaces/FlagsInterface.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";

contract EthBtcPriceOracle is IPriceOracle {
    /// @dev Identifier of the Sequencer offline flag on the Flags contract
    address private constant FLAG_ARBITRUM_SEQ_OFFLINE =
        address(
            bytes20(
                bytes32(
                    uint256(keccak256("chainlink.flags.arbitrum-seq-offline")) -
                        1
                )
            )
        );

    /// @dev ETH/USD priceFeed
    AggregatorV3Interface internal immutable ethPriceFeed;

    /// @dev BTC/USD priceFeed
    AggregatorV3Interface internal immutable wbtcPriceFeed;

    /// @dev Chainlink Flags
    FlagsInterface internal immutable chainlinkFlags;

    constructor() {
        /**
         * Network: Arbitrum Mainnet
         * Aggregators: ETH/USD WBTC/USD
         * Agg Addresses: 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612 0xd0c7101eacbb49f3decccc166d238410d6d46d57
         * Flags Address: 0x3C14e07Edd0dC67442FA96f1Ec6999c57E810a83
         */
        ethPriceFeed = AggregatorV3Interface(
            0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
        );
        wbtcPriceFeed = AggregatorV3Interface(
            0xd0C7101eACbB49F3deCcCc166d238410D6D46d57
        );
        chainlinkFlags = FlagsInterface(
            0x3C14e07Edd0dC67442FA96f1Ec6999c57E810a83
        );
    }

    /// @notice Returns the collateral price
    function getCollateralPrice() external view returns (uint256) {
        return getUnderlyingPrice();
    }

    /// @notice Returns the underlying price (tokenDecimals + 2)
    function getUnderlyingPrice() public view returns (uint256) {
        bool isRaised = chainlinkFlags.getFlag(FLAG_ARBITRUM_SEQ_OFFLINE);
        if (isRaised) {
            revert("Price feeds not being updated");
        }
        (, int256 ethPrice, , , ) = ethPriceFeed.latestRoundData();
        (, int256 wbtcPrice, , , ) = wbtcPriceFeed.latestRoundData();

        return uint256((10 ** (18 + 2)) * wbtcPrice / ethPrice);
    }
}