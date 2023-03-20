// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IOptionScalp} from "../interface/IOptionScalp.sol";

contract Keeper {
    /// @notice Owner/deployer of keeper contract
    address public owner;

    /// @notice Mapping to store whitelisted keepers who can call closePositions()
    /// @dev address of the keeper => whitelisted or not
    mapping(address => bool) public whitelistedKeepers;

    event WhitelistedKeeperSetAs(address _keeper, bool _setAs);

    constructor() {
        owner = msg.sender;
        whitelistedKeepers[msg.sender] = true;
    }

    /**
     * @notice Query for positions that can be closed. Conditions required are
     *         where the position is within exercise time frame or is liquidatable.
     * @param  _startIndex          Start index of position ids.
     * @param  _endIndex            Ending index of position ids.
     * @param  _scalpContract       Address of the option scalp contract.
     * @return _closeablePositions  positions that can closed.
     */
    function getCloseablePositions(
        uint256 _startIndex,
        uint256 _endIndex,
        address _scalpContract
    ) external view returns (uint256[] memory _closeablePositions) {
        IOptionScalp scalpContract = IOptionScalp(_scalpContract);
        IOptionScalp.ScalpPosition memory scalpPosition;

        _closeablePositions = new uint256[](_endIndex - _startIndex);

        do {
            scalpPosition = scalpContract.scalpPositions(_startIndex);

            if (isPositionClosable(_startIndex, _scalpContract)) {
                _closeablePositions[_startIndex] = _startIndex;
            }
            unchecked {
                ++_startIndex;
            }
        } while (_startIndex <= _endIndex);
    }

    /**
     * @notice Closes scalp positions of a given position ids.
     * @param _positionIds   Array of the position ids.
     * @param _scalpContract Address of the option scalp contract.
     */
    function closePositions(
        uint256[] memory _positionIds,
        address _scalpContract
    ) external {
        require(
            whitelistedKeepers[msg.sender],
            "KEEPER: CALLER NOT WHITELSITED"
        );
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

    /**
     * @notice Set a keeper as whitelisted or not.
     * @dev Only callable by owner/deployer.
     * @param _keeper Address of the keeper.
     * @param _setAs  True to whitelist, false to de-whitelist.
     */
    function setWhitelistedKeeper(address _keeper, bool _setAs) external {
        require(msg.sender == owner, "KEEPER: NOT OWNER");
        whitelistedKeepers[_keeper] = _setAs;
        emit WhitelistedKeeperSetAs(_keeper, _setAs);
    }

    /**
    * @notice Check if a position is close able or not.
    * @param _positionId           ID of the scalp position.
    * @param _optionScalpContract Address of the option scalp contract.
    * @return _isCloseable Whether the position can be closed or not.
     */
    function isPositionClosable(
        uint256 _positionId,
        address _optionScalpContract
    ) public view returns (bool _isCloseable) {
        IOptionScalp scalpContract = IOptionScalp(_optionScalpContract);
        IOptionScalp.ScalpPosition memory scalpPosition = IOptionScalp(
            _optionScalpContract
        ).scalpPositions(_positionId);

        if (scalpPosition.isOpen) {
            // Check if position is liquidatable
            bool isLiquidatable = scalpContract.isLiquidatable(_positionId);

            // // Check if within expiry window
            bool isWithinExpiryWindow = block.timestamp >=
                scalpPosition.openedAt + scalpPosition.timeframe;

            if (isLiquidatable || isWithinExpiryWindow) {
                return true;
            }
        }
    }
}
