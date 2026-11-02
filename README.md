# TracePay 📦💳

> **Trust-minimized, decentralized supply-chain trade finance powered by Ethereum & Chainlink.**

TracePay automates the trade finance lifecycle between buyers, suppliers, logistics verifiers, and financiers within a single smart contract. It eliminates intermediary delays and letter-of-credit friction using programmable escrow, real-time oracle pricing, milestone tracking, and on-chain invoice factoring.

---

## ✨ Key Features

- **USD-Pegged Escrow via Chainlink Oracles**: Buyers fund orders denominated in USD; the contract converts and locks the exact required ETH based on live, validated Chainlink price feeds.
- **Milestone-Based Releases**: 3PL / logistics verifiers record shipment milestones (`Dispatched` → `Delivered`) linked to tamper-evident IPFS proof-of-delivery CIDs.
- **Delegation of Authority (DoA)**: Enforces multi-signature approval from independent financial approvers for high-value transactions exceeding a configurable threshold.
- **On-Chain Invoice Factoring**: Suppliers can request immediate working capital (90% advance). Financiers provide upfront liquidity and are repaid with fees via an automated waterfall on delivery.
- **Security & Pull-Payment Ledger**: Implements OpenZeppelin RBAC (`AccessControl`), reentrancy protection (`ReentrancyGuard`), and checks-effects-interactions pull withdrawals.

---

## 🛠 Tech Stack

- **Smart Contracts**: Solidity `^0.8.20`, OpenZeppelin Contracts v5
- **Oracle**: Chainlink Data Feeds (`ETH/USD`)
- **Development & Testing**: Hardhat, Ethers.js v6, Mocha / Chai
- **Storage**: IPFS (evidence hashes & milestone receipts)
- **Frontend**: HTML5, Vanilla JavaScript, Ethers.js, MetaMask

---

## 🚀 Quick Start

### 1. Installation & Testing
```bash
npm install --legacy-peer-deps

# Run full test suite (16 tests: 6 functional + 10 revert/security tests)
npx hardhat test
```

### 2. Deployment (Sepolia Testnet)
```bash
cp .env.example .env  # Add private keys, RPC URLs & role addresses
npx hardhat run scripts/deploy.js --network sepolia
```

### 3. Frontend
Open `frontend/index.html` in your browser (or deploy `/frontend` to Vercel/Netlify) and connect your MetaMask wallet.

---

## 📄 Academic Paper
An IEEE standard conference paper format LaTeX document detailing the architecture, formal verification, gas analysis, and security model is available under [`paper/`](./paper/).
