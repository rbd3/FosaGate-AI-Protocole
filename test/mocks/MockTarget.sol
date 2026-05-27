// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockTarget {
    bool public wasCalled;
    bytes public lastPayload;
    uint256 public lastValue;

    function executeAction(uint256 /* x */) external payable {
        wasCalled = true;
        lastPayload = msg.data;
        lastValue = msg.value;
    }

    receive() external payable {
        wasCalled = true;
        lastValue = msg.value;
    }
}
