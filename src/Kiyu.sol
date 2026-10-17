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
    uint256 public nextId;
    mapping(uint256 => Payment) public payments;

    // ---------- Event ----------

    event Sent(uint256 indexed id, address indexed sender, address indexed recipient, uint256 amount);
    event Accepted(uint256 indexed id);
    event Rejected(uint256 indexed id);
    event Refunded(uint256 indexed id);

    // ---------- Function ----------
    // - always update status + emit before send money, otherwise hacker keep call send function since the status always Pending
    // - e.g. reentrancy attack behind 2016 DAO hacking

    function send(address recipient) public payable returns (uint256 id) {
        require(msg.value > 0, "Must send some ETH");
        require(recipient != address(0), "Invalid payment");
        require(recipient != msg.sender, "Cannot send to yourself");
        
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

