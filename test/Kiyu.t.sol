// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Kiyu.sol";
import "../src/MockUSDC.sol";

contract KiyuTest is Test {
    Kiyu kiyu;
    MockUSDC usdc;
    uint256 constant USDC = 1e6;    // 1 USDC = 1,000,000 units (6 decimals)
    address jay = address(0x1);     // sender
    address ali = address(0x2);     // receiver
    address mei = address(0x3);     // stranger

    function setUp() public {
        usdc = new MockUSDC();
        kiyu = new Kiyu(usdc);
        usdc.mint(jay, 10 * USDC);
        vm.prank(jay);
        usdc.approve(address(kiyu), type(uint256).max);
    }

    // ---------- Helper ----------
    // - Jay sends 1 USDC to Ali, returns the payment id

    function _jaySendsToAli() internal returns (uint256) {
        vm.prank(jay);
        return kiyu.send(ali, 1 * USDC);
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
        kiyu.send(ali, 1 * USDC);
    }

    function test_CannotSendToBlockedRecipient() public {
        kiyu.setBlocked(ali, true);
        vm.prank(jay);
        vm.expectRevert("Recipient is blocked");
        kiyu.send(ali, 1 * USDC);
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
        assertEq(usdc.balanceOf(ali), 0);
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

    function test_CannotSendWithoutApproval() public {
        usdc.mint(mei, 5 * USDC);       // Mei has USDC but never approved Kiyu
        vm.prank(mei);
        vm.expectRevert();              // the token itself refuses the tranfer
        kiyu.send(ali, 1* USDC);
    }

    function test_CannotSendMoreThanBalance() public {
        vm.prank(jay);
        vm.expectRevert();              // Jay only has 10 USDC
        kiyu.send(ali, 11* USDC);
    }

    function test_SendHoldsMoneyInContract() public {
        _jaySendsToAli();
        assertEq(usdc.balanceOf(address(kiyu)), 1 * USDC);
        assertEq(usdc.balanceOf(ali), 0);
        assertEq(usdc.balanceOf(jay), 9 * USDC);
    }

    function test_CannotSendZero() public {
        vm.prank(jay);
        vm.expectRevert("Amount must be more than 0");
        kiyu.send(ali, 0);
    }

    function test_CannotSendToYourself() public {
        vm.prank(jay);
        vm.expectRevert("Cannot send to yourself");
        kiyu.send(jay, 1 * USDC);
    }

    // ---------- Accept ----------

    function test_RecipientCanAccept() public {
        uint256 id = _jaySendsToAli();
        vm.prank(ali);
        kiyu.accept(id);
        assertEq(usdc.balanceOf(ali), 1 * USDC);
        assertEq(usdc.balanceOf(address(kiyu)), 0);
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
        assertEq(usdc.balanceOf(jay), 10 * USDC);
        assertEq(usdc.balanceOf(ali), 0);
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
        assertEq(usdc.balanceOf(address(kiyu)), 0);
        assertEq(usdc.balanceOf(jay), 10 * USDC);
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