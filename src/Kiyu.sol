// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Kiyu {

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

    constructor() {
        owner = msg.sender;
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

    function send(address recipient) public payable returns (uint256 id) {
        require(msg.value > 0, "Must send some ETH");
        require(recipient != address(0), "Invalid recipient");
        require(recipient != msg.sender, "Cannot send to yourself");
        require(!blocked[msg.sender], "Sender is blocked");
        require(!blocked[recipient], "Recipient is blocked");
        
        id = nextId;
        nextId++;

        payments[id] = Payment({
            sender: msg.sender,
            recipient: recipient,
            amount: msg.value,
            deadline: block.timestamp + WAIT_TIME,
            status: Status.Pending
        });

        emit Sent(id, msg.sender, recipient, msg.value);
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
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }
}

