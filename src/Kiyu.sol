// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Kiyu {
    using SafeERC20 for IERC20;

    // ---------- Data types ----------

    enum Status { Pending, Accepted, Rejected, Refunded }
    struct Payment {
        address sender;
        address recipient;
        uint256 amount;
        uint256 deadline;
        Status status;
    }

    // ---------- Storage ----------

    IERC20 public immutable token;

    uint256 public constant WAIT_TIME = 7 days;

    address public owner;
    mapping(address => bool) public blocked;

    uint256 public constant VOTES_NEEDED = 5;
    mapping(address => bool) public isReviewer;
    mapping(uint256 => bool) public paymentReported;
    mapping(address => uint256) public reportCount;
    mapping(address => uint256) public blockVotes;
    mapping(address => mapping(address => bool)) public hasVoted;

    uint256 public nextId;
    mapping(uint256 => Payment) public payments;

    // ---------- Event ----------

    event BlockedUpdated(address indexed account, bool isBlocked);
    
    event Reported(uint256 indexed id, address indexed reporter, address indexed reported);
    event VotedToBlock(address indexed reviewer, address indexed account, uint256 votes);

    event Sent(uint256 indexed id, address indexed sender, address indexed recipient, uint256 amount);
    event Accepted(uint256 indexed id);
    event Rejected(uint256 indexed id);
    event Refunded(uint256 indexed id);

    // ---------- Screening ----------

    constructor(IERC20 _token) {
        owner = msg.sender;
        token = _token;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function setBlocked(address account, bool isBlocked) public onlyOwner {
        blocked[account] = isBlocked;
        emit BlockedUpdated(account, isBlocked);
    }

    // ---------- Community reports ----------

    modifier onlyReviewer() {
        require(isReviewer[msg.sender], "Not reviewer");
        _;
    }    

    function setReviewer(address reviewer, bool active) public onlyOwner {
        isReviewer[reviewer] = active;
    }

    function report(uint256 id) public {
        Payment storage p = payments[id];
        require(msg.sender == p.recipient, "Not the recipient");
        require(!paymentReported[id], "Already reported");

        paymentReported[id] = true;
        reportCount[p.sender]++;
        emit Reported(id, msg.sender, p.sender);
    }

    function voteToBlock(address account) public onlyReviewer {
        require(reportCount[account] > 0, "No reports");
        require(!blocked[account], "Already blocked");
        require(!hasVoted[account][msg.sender], "Already voted");

        hasVoted[account][msg.sender] = true;
        blockVotes[account]++;
        emit VotedToBlock(msg.sender, account, blockVotes[account]);

        if (blockVotes[account] >= VOTES_NEEDED) {
            blocked[account] = true;
            emit BlockedUpdated(account, true);
        }
    }


    // ---------- Function ----------
    // - always update status + emit before send money, otherwise hacker keep call accept() since the status always Pending
    // - e.g. reentrancy attack behind 2016 DAO hacking

    function send(address recipient, uint256 amount) public returns (uint256 id) {
        require(amount > 0, "Amount must be more than 0");
        require(recipient != address(0), "Invalid recipient");
        require(recipient != msg.sender, "Cannot send to yourself");
        require(!blocked[msg.sender], "Sender is blocked");
        require(!blocked[recipient], "Recipient is blocked");

        id = nextId;
        nextId++;

        payments[id] = Payment({
            sender: msg.sender,
            recipient: recipient,
            amount: amount,
            deadline: block.timestamp + WAIT_TIME,
            status: Status.Pending
        });

        emit Sent(id, msg.sender, recipient, amount);

        // pull the tokens from sender into Kiyu
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function accept(uint256 id) public {
        Payment storage p = payments[id];
        require(msg.sender == p.recipient, "Not the recipient");
        require(p.status == Status.Pending, "Not pending");
        require(block.timestamp <= p.deadline, "Too late");
        require(!blocked[p.sender], "Sender is blocked");

        p.status = Status.Accepted;
        emit Accepted(id);
        _pay(p.recipient, p.amount);  
    }

    function reject(uint256 id) public {
        Payment storage p = payments[id];
        require(msg.sender == p.recipient, "Not the recipient");
        require(p.status == Status.Pending, "Not pending");

        p.status = Status.Rejected;
        emit Rejected(id);
        _pay(p.sender, p.amount);
    }

    function refund(uint256 id) public {
        Payment storage p = payments[id];
        require(msg.sender == p.sender, "Not the sender");
        require(p.status == Status.Pending, "Not pending");
        require(block.timestamp > p.deadline, "Still waiting");

        p.status = Status.Refunded;
        emit Refunded(id);
        _pay(p.sender, p.amount); 
    }

    // ---------- Helper ----------

    function _pay(address to, uint256 amount) internal {
        token.safeTransfer(to, amount);
    }
}

