// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;


contract AccountCore {
    function getAllAdmins() external view returns (address[] memory) {
        return new address[](0);
    }
}