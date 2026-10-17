// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Kiyu.sol";

// Functions attacker needs from any Kiyu-like contract
interface IKiyu {
    function send(address recipient) external payable returns (uint256);
    function accept(uint256 id) external;
}

// Broken copy of Kiyu: pays money before updating the status
contract VulnerableKiyu {
    struct Payment { address recipient; uint256 amount; bool done; }
    mapping(uint256 => Payment) public payments;
    uint256 public nextId;

    function send(address recipient) external payable returns (uint256 id) {
        id = nextId++;
        payments[id] = Payment(recipient, msg.value, false);
    }

    function accept(uint256 id) external {
        Payment storage p = payments[id];
        require(msg.sender == p.recipient, "Not the recipient");
        require(!p.done, "Not pending");

        (bool ok, ) = p.recipient.call{value: p.amount}("");    // pay first
        require(ok, "ETH transfer failed");
        p.done = true;                                          // update last
    }
}

// Contract that calls accept() again while being paid
contract Attacker {
    IKiyu public target;
    uint256 public paymentId;
    uint256 public reentries;

    constructor(IKiyu _target) {
        target = _target;
    }

    function setPaymentId(uint256 id) external {
        paymentId = id;
    }

    function attack() external {
        target.accept(paymentId);
    }

    // Runs automatically every time this contract receives ETH
    receive() external payable {
        if (address(target).balance >= 1 ether && reentries < 10) {
            reentries++;
            try target.accept(paymentId) {} catch {}    // try to get paid again
        }
    }
}

contract ReentrancyTest is Test {
    address jay = address(0x1);
    address victim = address(0x9);

    function test_VulnerableVersionGetsDrained() public {
        VulnerableKiyu bad = new VulnerableKiyu();
        Attacker attacker = new Attacker(IKiyu(address(bad)));

        // Other users have 5 ETH waiting in the contract
        vm.deal(jay, 10 ether);
        vm.startPrank(jay);
        for (uint256 i = 0; i < 5; i++) {
            bad.send{value: 1 ether}(victim);
        }
        
        // Jay sends 1 ETH to the attacker
        uint256 id = bad.send{value: 1 ether}(address(attacker));
        vm.stopPrank();
        attacker.setPaymentId(id);

        attacker.attack();

        console.log("Attacker should get: 1 ETH");
        console.log("Attacker actually got (wei): ", address(attacker).balance);
        assertEq(address(attacker).balance, 6 ether);   // stole everyone's money
        assertEq(address(bad).balance, 0);
    }

    function test_KiyuIsSafe() public {
        Kiyu kiyu = new Kiyu();
        Attacker attacker = new Attacker(IKiyu(address(kiyu)));

        // Other users have 5 ETH waiting in the contract
        vm.deal(jay, 10 ether);
        vm.startPrank(jay);
        for (uint256 i = 0; i < 5; i++) {
            kiyu.send{value: 1 ether}(victim);
        }

        // Jay sends 1 ETH to the attacker
        uint256 id = kiyu.send{value: 1 ether}(address(attacker));
        vm.stopPrank();
        attacker.setPaymentId(id);

        attacker.attack();

        console.log("Re-entry attempts: ", attacker.reentries());
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(kiyu).balance, 5 ether);       // everyone else's money safe
    }
}