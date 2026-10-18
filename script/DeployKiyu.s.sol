// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Kiyu.sol";
import "../src/MockUSDC.sol";

// Local test setup: a fake USDC + Kiyu, and 10,000 USDC for the first 3 Anvil accounts
contract DeployKiyu is Script {
    function run() external {
        vm.startBroadcast();

        MockUSDC usdc = new MockUSDC();
        Kiyu kiyu = new Kiyu(usdc);

        usdc.mint(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, 10_000e6);   // Jay  (account 0)
        usdc.mint(0x70997970C51812dc3A010C7d01b50e0d17dc79C8, 10_000e6);   // Ali  (account 1)
        usdc.mint(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, 10_000e6);   // Mei  (account 2)

        vm.stopBroadcast();
        console.log("MockUSDC deployed at: ", address(usdc));
        console.log("Kiyu deployed at: ", address(kiyu));
    }
}