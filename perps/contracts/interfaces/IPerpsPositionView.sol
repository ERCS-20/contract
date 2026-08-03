// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPerpsPositionView {
    function hasOpenPosition(address user) external view returns (bool);
}
