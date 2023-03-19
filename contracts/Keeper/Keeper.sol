// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IOptionScalp} from "../interface/IOptionScalp.sol";

import "hardhat/console.sol";

contract Keeper {
    address public owner;
    mapping(address => uint256) public whitelistedKeepers;

    event WhitelistedKeeperSetAs(address _keeper, uint256 _setAs);

    constructor() {
        owner = msg.sender;
    }

    function getCloseablePositions(
        uint256 _startIndex,
        uint256 _endIndex,
        address _scalpContract
    ) external view returns (uint256[] memory _closeablePositions) {
        IOptionScalp scalpContract = IOptionScalp(_scalpContract);
        IOptionScalp.ScalpPosition memory scalpPosition;

        _closeablePositions = new uint256[](_endIndex - _startIndex);

        bool isWithinExpiryWindow;
        bool isLiquidatable;

        do {
            scalpPosition = scalpContract.scalpPositions(_startIndex);

            if (scalpPosition.isOpen) {
                // Check if position is liquidatable
                isLiquidatable = scalpContract.isLiquidatable(_startIndex);

                // // Check if within expiry window
                isWithinExpiryWindow =
                    block.timestamp >=
                    scalpPosition.openedAt + scalpPosition.timeframe;

                console.log(
                    scalpPosition.openedAt,
                    scalpPosition.timeframe,
                    block.timestamp
                );

                console.log("Expiry window", isWithinExpiryWindow);

                if (isLiquidatable || isWithinExpiryWindow) {
                    _closeablePositions[_startIndex] = _startIndex;
                }
            }
            unchecked {
                ++_startIndex;
            }
        } while (_startIndex <= _endIndex);
    }

    function closePositions(
        uint256[] memory _positionIds,
        address _scalpContract
    ) external {
        uint256 startIndex;
        do {
            console.log(_positionIds[startIndex]);
            IOptionScalp(_scalpContract).closePosition(
                _positionIds[startIndex]
            );

            unchecked {
                 ++startIndex;
            }
        } while (startIndex < _positionIds.length);
    }

    function setWhitelistedKeeper(address _keeper, uint256 _setAs) external {
        require(msg.sender == owner, "KEEPER: NOT OWNER");
        whitelistedKeepers[_keeper] = _setAs;
        emit WhitelistedKeeperSetAs(_keeper, _setAs);
    }
}
