// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Kiyu.sol";

// Deploy Kiyu to Sepolia, using Circle's real test USDC (no MockUSDC here)
contract DeployKiyuSepolia is Script {
    IERC20 constant USDC = IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);

    function run() external {
        vm.startBroadcast();
        Kiyu kiyu = new Kiyu(USDC);
        vm.stopBroadcast();

        console.log("Kiyu deployed at: ", address(kiyu));
        console.log("Owner:            ", kiyu.owner());
    }
}