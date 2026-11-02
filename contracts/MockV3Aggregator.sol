// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test-only price feed so unit tests can simulate normal, stale and invalid prices.
contract MockV3Aggregator {
    uint8 public immutable decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _round;

    constructor(uint8 _decimals, int256 initialAnswer) {
        decimals = _decimals;
        setPrice(initialAnswer);
    }

    function setPrice(int256 a) public { _answer = a; _updatedAt = block.timestamp; _round++; }
    function setUpdatedAt(uint256 t) external { _updatedAt = t; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }
}
