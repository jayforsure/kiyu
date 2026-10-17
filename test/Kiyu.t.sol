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

    // ---------- Screening ----------

    function test_OwnerCanBlock() public {
        kiyu.setBlocked(mei, true);
        assertTrue(kiyu.blocked(mei));
    }

    function test_OthersCannotBlock() public {
        vm.prank(mei);
        vm.expectRevert("Not owner");
        kiyu.setBlocked(ali, true);
    }

    function test_BlockedSenderCannotSend() public {
        kiyu.setBlocked(jay, true);
        vm.prank(jay);
        vm.expectRevert("Sender is blocked");
        kiyu.send{value: 1 ether}(ali);
    }

    function test_CannotSendToBlockedRecipient() public {
        kiyu.setBlocked(ali, true);
        vm.prank(jay);
        vm.expectRevert("Recipient is blocked");
        kiyu.send{value: 1 ether}(ali);
    }

    function test_CannotAcceptIfSenderBlockedLater() public {
        uint256 id = _jaySendsToAli();
        kiyu.setBlocked(jay, true);
        vm.prank(ali);
        vm.expectRevert("Sender is blocked");
        kiyu.accept(id);
    }

    function test_CanStillRejectIfSenderBlocked() public {
        uint256 id = _jaySendsToAli();
        kiyu.setBlocked(jay, true);
        vm.prank(ali);
        kiyu.reject(id);
        assertEq(ali.balance, 0);
    }

    // ---------- Community reports + votes ----------

    address r1 = address(0x11);
    address r2 = address(0x12);
    address r3 = address(0x13);
    address r4 = address(0x14);
    address r5 = address(0x15);
    address r6 = address(0x16);
    address r7 = address(0x17);

    function _addReviewers() internal {
        kiyu.setReviewer(r1, true);
        kiyu.setReviewer(r2, true);
        kiyu.setReviewer(r3, true);
        kiyu.setReviewer(r4, true);
        kiyu.setReviewer(r5, true);
        kiyu.setReviewer(r6, true);
        kiyu.setReviewer(r7, true);
    }

    function test_RecipientCanReport() public {
        uint256 id = _jaySendsToAli();
        vm.prank(ali);
        kiyu.report(id);
        assertEq(kiyu.reportCount(jay), 1);
    }

    function test_StrangerCannotReport() public {
        uint256 id = _jaySendsToAli();
        vm.prank(mei);
        vm.expectRevert("Not the recipient");
        kiyu.report(id);
    }

    function test_CannotReportSamePaymentTwice() public {
        uint256 id = _jaySendsToAli();
        vm.startPrank(ali);
        kiyu.report(id);
        vm.expectRevert("Already reported");
        kiyu.report(id);
        vm.stopPrank();
    }

    function test_CannotVoteWithoutReport() public {
        _addReviewers();
        vm.prank(r1);
        vm.expectRevert("No reports");
        kiyu.voteToBlock(jay);
    }

    function test_NonReviewerCannotVote() public {
        vm.prank(ali);
        vm.expectRevert("Not reviewer");
        kiyu.voteToBlock(jay);
    }

    function test_ReviewerCannotVoteTwice() public {
        _addReviewers();
        uint256 id = _jaySendsToAli();
        vm.prank(ali);
        kiyu.report(id);
        vm.startPrank(r1);
        kiyu.voteToBlock(jay);
        vm.expectRevert("Already voted");
        kiyu.voteToBlock(jay);
        vm.stopPrank();
    }

    function test_FiveVotesBlock() public {
        _addReviewers();
        uint256 id = _jaySendsToAli();
        vm.prank(ali);
        kiyu.report(id);

        vm.prank(r1);
        kiyu.voteToBlock(jay);
        vm.prank(r2);
        kiyu.voteToBlock(jay);
        vm.prank(r3);
        kiyu.voteToBlock(jay);
        vm.prank(r4);
        kiyu.voteToBlock(jay);
        assertFalse(kiyu.blocked(jay));

        vm.prank(r5);
        kiyu.voteToBlock(jay);
        assertTrue(kiyu.blocked(jay));
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