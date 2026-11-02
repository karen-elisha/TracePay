// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal Chainlink Data Feed interface (same ABI as AggregatorV3Interface).
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title TracePay - supply-chain trade finance on Ethereum
/// @notice Escrow + milestone verification + DoA multi-approval + oracle pricing + invoice financing.
contract TracePay is AccessControl, ReentrancyGuard {
    // ───────────── Roles (RBAC) ─────────────
    bytes32 public constant VERIFIER_ROLE  = keccak256("VERIFIER_ROLE");   // logistics verifier
    bytes32 public constant APPROVER_ROLE  = keccak256("APPROVER_ROLE");   // finance approver (DoA)
    bytes32 public constant FINANCIER_ROLE = keccak256("FINANCIER_ROLE");  // invoice financier / lender

    // ───────────── Data model ─────────────
    enum Status { Created, Funded, Dispatched, Delivered, Settled, Refunded }

    struct Order {
        address buyer;
        address supplier;
        bytes32 invoiceHash;      // keccak256 of the off-chain invoice (privacy + duplicate check)
        uint256 invoiceUsd;       // invoice value in USD, 8 decimals (same as Chainlink USD feeds)
        uint256 escrowWei;        // ETH locked in escrow
        uint256 lockedPrice;      // ETH/USD price used at funding (audit trail)
        uint64  deadline;         // delivery deadline (unix)
        Status  status;
        uint8   approvals;        // DoA approvals collected
        // invoice financing (factoring)
        bool    financeRequested;
        address financier;
        uint256 financierDueWei;  // advance + fee owed to the financier from escrow
    }

    IPriceFeed public immutable priceFeed;

    uint256 public orderCount;
    mapping(uint256 => Order) public orders;
    mapping(bytes32 => bool) public invoiceRegistered;                 // duplicate-invoice guard
    mapping(uint256 => mapping(address => bool)) public hasApproved;   // one approval per approver
    mapping(address => uint256) public claimable;                      // pull-payment ledger

    // Delegation of Authority policy
    uint256 public doaThresholdUsd;   // orders >= this value need multi-approval (8 decimals)
    uint8   public requiredApprovals; // number of distinct approvers

    // Oracle + financing parameters
    uint256 public maxPriceAge = 2 hours;  // Sepolia ETH/USD heartbeat is 1 hour
    uint16  public advanceBps  = 9000;     // financier advances 90% of escrow
    uint16  public feeBps      = 200;      // financing fee = 2% of the advance

    // ───────────── Events (audit trail) ─────────────
    event OrderCreated(uint256 indexed id, address indexed buyer, address indexed supplier, bytes32 invoiceHash, uint256 invoiceUsd, uint64 deadline);
    event OrderFunded(uint256 indexed id, uint256 weiLocked, uint256 ethUsdPrice);
    event MilestoneRecorded(uint256 indexed id, Status milestone, string evidenceCid, address verifier);
    event ApprovalGranted(uint256 indexed id, address indexed approver, uint8 approvals);
    event PaymentReleased(uint256 indexed id, uint256 toSupplier, uint256 toFinancier);
    event Refunded(uint256 indexed id, uint256 amount);
    event FinancingRequested(uint256 indexed id, address indexed supplier);
    event FinancingFunded(uint256 indexed id, address indexed financier, uint256 advanceWei, uint256 dueWei);
    event Withdrawn(address indexed account, uint256 amount);
    event PolicyUpdated(uint256 doaThresholdUsd, uint8 requiredApprovals);

    constructor(address feed, uint256 _doaThresholdUsd, uint8 _requiredApprovals) {
        require(feed != address(0), "feed=0");
        priceFeed = IPriceFeed(feed);
        doaThresholdUsd = _doaThresholdUsd;
        requiredApprovals = _requiredApprovals;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ───────────── Oracle ─────────────
    /// @notice Latest validated ETH/USD price (raw, feed decimals).
    function latestPrice() public view returns (uint256 price) {
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(answer > 0, "oracle: price<=0");
        require(updatedAt != 0 && answeredInRound >= roundId, "oracle: incomplete round");
        require(block.timestamp - updatedAt <= maxPriceAge, "oracle: stale price");
        price = uint256(answer);
    }

    /// @notice Convert a USD amount (8 decimals) into wei using the live feed.
    function usdToWei(uint256 usd8) public view returns (uint256) {
        uint256 p = latestPrice();
        uint8 d = priceFeed.decimals();
        return (usd8 * (10 ** d) * 1e18) / (p * 1e8);
    }

    /// @notice Wei the buyer must lock right now for a given order.
    function quoteWei(uint256 id) external view returns (uint256) {
        return usdToWei(orders[id].invoiceUsd);
    }

    // ───────────── 1. Order + invoice ─────────────
    function createOrder(address supplier, bytes32 invoiceHash, uint256 invoiceUsd, uint64 deadline)
        external returns (uint256 id)
    {
        require(supplier != address(0) && supplier != msg.sender, "bad supplier");
        require(invoiceUsd > 0, "invoice=0");
        require(deadline > block.timestamp, "deadline in past");
        require(!invoiceRegistered[invoiceHash], "duplicate invoice");

        invoiceRegistered[invoiceHash] = true;
        id = ++orderCount;
        Order storage o = orders[id];
        o.buyer = msg.sender;
        o.supplier = supplier;
        o.invoiceHash = invoiceHash;
        o.invoiceUsd = invoiceUsd;
        o.deadline = deadline;
        o.status = Status.Created;
        emit OrderCreated(id, msg.sender, supplier, invoiceHash, invoiceUsd, deadline);
    }

    // ───────────── 2. Escrow funding (oracle-priced) ─────────────
    function fundOrder(uint256 id) external payable nonReentrant {
        Order storage o = orders[id];
        require(msg.sender == o.buyer, "only buyer");
        require(o.status == Status.Created, "not fundable");

        uint256 required = usdToWei(o.invoiceUsd);
        require(msg.value >= required, "insufficient ETH");

        o.status = Status.Funded;           // effects first
        o.escrowWei = required;
        o.lockedPrice = latestPrice();
        emit OrderFunded(id, required, o.lockedPrice);

        uint256 excess = msg.value - required;
        if (excess > 0) claimable[msg.sender] += excess;   // overpayment returned via pull-payment
    }

    // ───────────── 3. Shipment milestones ─────────────
    function recordMilestone(uint256 id, Status milestone, string calldata evidenceCid)
        external onlyRole(VERIFIER_ROLE)
    {
        Order storage o = orders[id];
        if (milestone == Status.Dispatched) {
            require(o.status == Status.Funded, "must be Funded");
        } else if (milestone == Status.Delivered) {
            require(o.status == Status.Dispatched, "must be Dispatched");
        } else {
            revert("invalid milestone");
        }
        o.status = milestone;
        emit MilestoneRecorded(id, milestone, evidenceCid, msg.sender);
    }

    // ───────────── 4. Delegation of Authority (multi-approval) ─────────────
    function isHighValue(uint256 id) public view returns (bool) {
        return orders[id].invoiceUsd >= doaThresholdUsd;
    }

    function approveRelease(uint256 id) external onlyRole(APPROVER_ROLE) {
        Order storage o = orders[id];
        require(o.status == Status.Delivered, "not delivered");
        require(msg.sender != o.buyer && msg.sender != o.supplier, "separation of duties");
        require(!hasApproved[id][msg.sender], "already approved");
        hasApproved[id][msg.sender] = true;
        o.approvals += 1;
        emit ApprovalGranted(id, msg.sender, o.approvals);
    }

    // ───────────── 5. Conditional settlement (payment waterfall) ─────────────
    function releasePayment(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        require(o.status == Status.Delivered, "not delivered");
        if (isHighValue(id)) require(o.approvals >= requiredApprovals, "DoA approvals missing");

        o.status = Status.Settled;          // effects before any value movement
        uint256 toFinancier = 0;
        if (o.financier != address(0)) {
            toFinancier = o.financierDueWei < o.escrowWei ? o.financierDueWei : o.escrowWei;
            claimable[o.financier] += toFinancier;
        }
        uint256 toSupplier = o.escrowWei - toFinancier;
        claimable[o.supplier] += toSupplier;
        emit PaymentReleased(id, toSupplier, toFinancier);
    }

    /// @notice Buyer recovers escrow if goods were not delivered by the deadline.
    function claimRefund(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        require(msg.sender == o.buyer, "only buyer");
        require(o.status == Status.Funded || o.status == Status.Dispatched, "not refundable");
        require(block.timestamp > o.deadline, "deadline not passed");
        o.status = Status.Refunded;
        claimable[o.buyer] += o.escrowWei;
        emit Refunded(id, o.escrowWei);
    }

    // ───────────── 6. Invoice financing (factoring) ─────────────
    function requestFinancing(uint256 id) external {
        Order storage o = orders[id];
        require(msg.sender == o.supplier, "only supplier");
        require(o.status == Status.Funded || o.status == Status.Dispatched, "escrow must be locked");
        require(!o.financeRequested, "already requested");
        o.financeRequested = true;
        emit FinancingRequested(id, msg.sender);
    }

    function financingQuote(uint256 id) public view returns (uint256 advanceWei, uint256 dueWei) {
        uint256 e = orders[id].escrowWei;
        advanceWei = (e * advanceBps) / 10_000;
        dueWei = advanceWei + (advanceWei * feeBps) / 10_000;
    }

    function fundFinancing(uint256 id) external payable onlyRole(FINANCIER_ROLE) nonReentrant {
        Order storage o = orders[id];
        require(o.financeRequested && o.financier == address(0), "not available");
        require(o.status == Status.Funded || o.status == Status.Dispatched, "escrow must be locked");
        (uint256 adv, uint256 due) = financingQuote(id);
        require(msg.value == adv, "send exact advance");

        o.financier = msg.sender;           // receivable is now assigned to the financier
        o.financierDueWei = due;
        claimable[o.supplier] += adv;       // supplier gets working capital immediately
        emit FinancingFunded(id, msg.sender, adv, due);
    }

    // ───────────── Pull payments ─────────────
    function withdraw() external nonReentrant {
        uint256 amt = claimable[msg.sender];
        require(amt > 0, "nothing to withdraw");
        claimable[msg.sender] = 0;          // checks-effects-interactions
        (bool ok, ) = payable(msg.sender).call{value: amt}("");
        require(ok, "transfer failed");
        emit Withdrawn(msg.sender, amt);
    }

    // ───────────── Admin policy ─────────────
    function setPolicy(uint256 _doaThresholdUsd, uint8 _requiredApprovals) external onlyRole(DEFAULT_ADMIN_ROLE) {
        doaThresholdUsd = _doaThresholdUsd;
        requiredApprovals = _requiredApprovals;
        emit PolicyUpdated(_doaThresholdUsd, _requiredApprovals);
    }

    function setFinancingTerms(uint16 _advanceBps, uint16 _feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_advanceBps <= 10_000 && _feeBps <= 5_000, "bad terms");
        advanceBps = _advanceBps;
        feeBps = _feeBps;
    }

    function setMaxPriceAge(uint256 secs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxPriceAge = secs;
    }
}
