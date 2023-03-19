// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IOptionScalp} from "../interface/IOptionScalp.sol";

contract Keeper {
    address public owner;
    mapping(address => bool) public whitelistedKeepers;

    event WhitelistedKeeperSetAs(address _keeper, bool _setAs);

    constructor() {
        owner = msg.sender;
        whitelistedKeepers[msg.sender] = true;
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
        require(whitelistedKeepers[msg.sender], "KEEPER: CALLER NOT WHITELSITED");
        uint256 startIndex;
        do {
            IOptionScalp(_scalpContract).closePosition(
                _positionIds[startIndex]
            );

            unchecked {
                 ++startIndex;
            }
        } while (startIndex < _positionIds.length);
    }

    function setWhitelistedKeeper(address _keeper, bool _setAs) external {
        require(msg.sender == owner, "KEEPER: NOT OWNER");
        whitelistedKeepers[_keeper] = _setAs;
        emit WhitelistedKeeperSetAs(_keeper, _setAs);
    }
}
