// Usage:  npx hardhat run scripts/deploy.js --network sepolia
// Optional .env: VERIFIER, APPROVER1, APPROVER2, FINANCIER (wallet addresses that get roles)
const { ethers, network } = require("hardhat");

const SEPOLIA_ETH_USD = "0x694AA1769357215DE4FAC081bf1f309aDC325306"; // Chainlink ETH/USD on Sepolia

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address, "| Network:", network.name);

  let feed = SEPOLIA_ETH_USD;
  if (network.name === "hardhat" || network.name === "localhost") {
    const Mock = await ethers.getContractFactory("MockV3Aggregator");
    const mock = await Mock.deploy(8, 2000n * 10n ** 8n);
    await mock.waitForDeployment();
    feed = await mock.getAddress();
    console.log("Mock price feed:", feed);
  }

  // DoA policy: invoices >= DOA_USD (default $50 so it is demo-able with small test ETH) need 2 distinct approvals
  const doaUsd = BigInt(process.env.DOA_USD || 50);
  const TracePay = await ethers.getContractFactory("TracePay");
  const tp = await TracePay.deploy(feed, doaUsd * 10n ** 8n, 2);
  await tp.waitForDeployment();
  const addr = await tp.getAddress();
  console.log("TracePay deployed at:", addr);
  console.log("Deploy block:", (await tp.deploymentTransaction().wait()).blockNumber);

  const grants = [
    ["VERIFIER_ROLE", process.env.VERIFIER],
    ["APPROVER_ROLE", process.env.APPROVER1],
    ["APPROVER_ROLE", process.env.APPROVER2],
    ["FINANCIER_ROLE", process.env.FINANCIER],
  ];
  for (const [role, who] of grants) {
    if (!who) continue;
    const tx = await tp.grantRole(ethers.id(role), who);
    await tx.wait();
    console.log(`Granted ${role} -> ${who}`);
  }
  console.log("\nNext: paste the address + deploy block into frontend/index.html (CONFIG).");
}
main().catch((e) => { console.error(e); process.exit(1); });
