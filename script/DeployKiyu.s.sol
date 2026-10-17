// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Kiyu.sol";

contract DeployKiyu is Script {
    function run() external {
        vm.startBroadcast();
        Kiyu kiyu = new Kiyu();
        vm.stopBroadcast();

        console.log("Kiyu deployed at: ", address(kiyu));
    }
}