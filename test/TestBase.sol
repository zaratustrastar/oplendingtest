// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface Vm {
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function deal(address account, uint256 newBalance) external;
    function warp(uint256 newTimestamp) external;
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function makeAddr(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }

    function bound(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        require(min <= max, "bound order");
        if (value < min || value > max) {
            return min + (value % (max - min + 1));
        }
        return value;
    }

    function assertTrue(bool condition) internal pure {
        require(condition, "assertTrue");
    }

    function assertFalse(bool condition) internal pure {
        require(!condition, "assertFalse");
    }

    function assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "assertEq uint256");
    }

    function assertEq(address actual, address expected) internal pure {
        require(actual == expected, "assertEq address");
    }

    function assertLe(uint256 actual, uint256 expectedMax) internal pure {
        require(actual <= expectedMax, "assertLe");
    }
}
