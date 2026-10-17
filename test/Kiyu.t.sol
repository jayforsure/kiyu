// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Kiyu.sol";

contract KiyuTest is Test {
    Kiyu kiyu;
    address jay = address(0x1);     // sender
    address ali = address(0x2);     // receiver
    address mei = address(0x3);     // stranger

    function setUp() public {
        kiyu = new Kiyu();
        vm.deal(jay, 10 ether);
    }

    // ---------- Helper ----------
    // - Jay sends 1 ETH to Ali, returns the payment id

    function _jaySendsToAli() internal returns (uint256) {
        vm.prank(jay);
        return kiyu.send{value: 1 ether}(ali);
    }

    // ---------- Send ----------

    function test_SendHoldsMoneyInContract() public {
        _jaySendsToAli();
        assertEq(address(kiyu).balance, 1 ether);
        assertEq(ali.balance, 0);
        assertEq(jay.balance, 9 ether);
    }

    function test_CannotSendZero() public {
        vm.prank(jay);
        vm.expectRevert("Must send some ETH");
        kiyu.send{value: 0}(ali);
    }

    function test_CannotSendToYourself() public {
        vm.prank(jay);
        vm.expectRevert("Cannot send to yourself");
        kiyu.send{value: 1 ether}(jay);
    }

    // ---------- Accept ----------

    function test_RecipientCanAccept() public {
        uint256 id = _jaySendsToAli();
        vm.prank(ali);
        kiyu.accept(id);
        assertEq(ali.balance, 1 ether);
        assertEq(address(kiyu).balance, 0);
    }

    function test_StrangerCannotAccept() public {
        uint256 id = _jaySendsToAli();
        vm.prank(mei);
        vm.expectRevert("Not the recipient");
        kiyu.accept(id);
    }

    function test_CannotAcceptTwice() public {
        uint256 id = _jaySendsToAli();
        vm.startPrank(ali);
        kiyu.accept(id);
        vm.expectRevert("Not pending");
        kiyu.accept(id);
        vm.stopPrank();
    }

    function test_CannotAcceptAfterDeadline() public {
        uint256 id = _jaySendsToAli();
        vm.warp(block.timestamp + 8 days);
        vm.prank(ali);
        vm.expectRevert("Too late");
        kiyu.accept(id);
    }

    // ---------- Reject ----------

    function test_RecipientCanReject() public {
        uint256 id = _jaySendsToAli();
        vm.prank(ali);
        kiyu.reject(id);
        assertEq(jay.balance, 10 ether);
        assertEq(ali.balance, 0);
    }

    function test_CannotAcceptAfterReject() public {
        uint256 id = _jaySendsToAli();
        vm.startPrank(ali);
        kiyu.reject(id);
        vm.expectRevert("Not pending");
        kiyu.accept(id);
        vm.stopPrank();
    }

    // ---------- Refund ----------

    function test_SenderCanRefundAfterDeadline() public {
        uint256 id = _jaySendsToAli();
        vm.warp(block.timestamp + 8 days);
        vm.prank(jay);
        kiyu.refund(id);
        assertEq(address(kiyu).balance, 0);
        assertEq(jay.balance, 10 ether);
    }

    function test_SenderCannotRefundEarly() public {
        uint256 id = _jaySendsToAli();
        vm.prank(jay);
        vm.expectRevert("Still waiting");
        kiyu.refund(id);
    }

    function test_StrangerCannotRefund() public {
        uint256 id = _jaySendsToAli();
        vm.warp(block.timestamp + 8 days);
        vm.prank(mei);
        vm.expectRevert("Not the sender");
        kiyu.refund(id);
    }
}