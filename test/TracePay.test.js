const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const USD = (n) => BigInt(n) * 10n ** 8n;            // USD with 8 decimals
const PRICE = 2000n * 10n ** 8n;                      // 1 ETH = $2000 (8 decimals)
const hash = (s) => ethers.keccak256(ethers.toUtf8Bytes(s));
const Status = { Created: 0, Funded: 1, Dispatched: 2, Delivered: 3, Settled: 4, Refunded: 5 };

describe("TracePay", function () {
  let tp, feed, admin, buyer, supplier, verifier, appr1, appr2, financier, stranger, deadline;

  beforeEach(async () => {
    [admin, buyer, supplier, verifier, appr1, appr2, financier, stranger] = await ethers.getSigners();
    feed = await (await ethers.getContractFactory("MockV3Aggregator")).deploy(8, PRICE);
    tp = await (await ethers.getContractFactory("TracePay")).deploy(await feed.getAddress(), USD(5000), 2);
    await tp.grantRole(await tp.VERIFIER_ROLE(), verifier.address);
    await tp.grantRole(await tp.APPROVER_ROLE(), appr1.address);
    await tp.grantRole(await tp.APPROVER_ROLE(), appr2.address);
    await tp.grantRole(await tp.FINANCIER_ROLE(), financier.address);
    deadline = (await time.latest()) + 7 * 24 * 3600;
  });

  const create = (usd = 1000, tag = "INV-1") =>
    tp.connect(buyer).createOrder(supplier.address, hash(tag), USD(usd), deadline);
  const fund = async (id = 1) => tp.connect(buyer).fundOrder(id, { value: await tp.quoteWei(id) });
  const toDelivered = async (id = 1) => {
    await tp.connect(verifier).recordMilestone(id, Status.Dispatched, "ipfs://dispatch");
    await tp.connect(verifier).recordMilestone(id, Status.Delivered, "ipfs://pod");
  };

  it("TC-01 happy path: create → fund (oracle) → dispatch → deliver → release → withdraw", async () => {
    await create(1000);
    expect(await tp.quoteWei(1)).to.equal(ethers.parseEther("0.5")); // $1000 / $2000
    await fund();
    await toDelivered();
    await tp.releasePayment(1);
    const before = await ethers.provider.getBalance(supplier.address);
    await tp.connect(supplier).withdraw();
    expect(await ethers.provider.getBalance(supplier.address)).to.be.gt(before);
    expect((await tp.orders(1)).status).to.equal(Status.Settled);
  });

  it("TC-02 oracle conversion is correct for different prices", async () => {
    await create(1000);
    await feed.setPrice(4000n * 10n ** 8n);
    expect(await tp.quoteWei(1)).to.equal(ethers.parseEther("0.25"));
  });

  it("TC-03 DoA: high-value order needs 2 distinct approvals before release", async () => {
    await create(6000);
    await fund(); await toDelivered();
    await expect(tp.releasePayment(1)).to.be.revertedWith("DoA approvals missing");
    await tp.connect(appr1).approveRelease(1);
    await expect(tp.releasePayment(1)).to.be.revertedWith("DoA approvals missing");
    await tp.connect(appr2).approveRelease(1);
    await expect(tp.releasePayment(1)).to.emit(tp, "PaymentReleased");
  });

  it("TC-04 invoice financing: waterfall pays financier first, remainder to supplier", async () => {
    await create(1000);
    await fund();
    await tp.connect(supplier).requestFinancing(1);
    const [adv, due] = await tp.financingQuote(1);
    expect(adv).to.equal(ethers.parseEther("0.45"));          // 90% of 0.5
    expect(due).to.equal(ethers.parseEther("0.459"));         // + 2% fee
    await tp.connect(financier).fundFinancing(1, { value: adv });
    expect(await tp.claimable(supplier.address)).to.equal(adv);
    await toDelivered();
    await tp.releasePayment(1);
    expect(await tp.claimable(financier.address)).to.equal(due);
    expect(await tp.claimable(supplier.address)).to.equal(adv + ethers.parseEther("0.041")); // advance + reserve
  });

  it("TC-05 refund after deadline when not delivered", async () => {
    await create(1000); await fund();
    await expect(tp.connect(buyer).claimRefund(1)).to.be.revertedWith("deadline not passed");
    await time.increaseTo(deadline + 10);
    await tp.connect(buyer).claimRefund(1);
    expect(await tp.claimable(buyer.address)).to.equal(ethers.parseEther("0.5"));
  });

  it("TC-06 overpayment is credited back to buyer", async () => {
    await create(1000);
    await tp.connect(buyer).fundOrder(1, { value: ethers.parseEther("0.8") });
    expect(await tp.claimable(buyer.address)).to.equal(ethers.parseEther("0.3"));
  });

  // ─────────── Negative tests (expected reverts) ───────────
  it("TC-07 NEG duplicate invoice hash is rejected", async () => {
    await create(1000, "INV-X");
    await expect(create(1000, "INV-X")).to.be.revertedWith("duplicate invoice");
  });

  it("TC-08 NEG stale oracle price blocks funding", async () => {
    await create(1000);
    await feed.setUpdatedAt((await time.latest()) - 3 * 3600);
    await expect(tp.connect(buyer).fundOrder(1, { value: ethers.parseEther("1") }))
      .to.be.revertedWith("oracle: stale price");
  });

  it("TC-09 NEG invalid (negative) oracle price blocks quoting", async () => {
    await create(1000);
    await feed.setPrice(-1);
    await expect(tp.quoteWei(1)).to.be.revertedWith("oracle: price<=0");
  });

  it("TC-10 NEG underfunding reverts", async () => {
    await create(1000);
    await expect(tp.connect(buyer).fundOrder(1, { value: ethers.parseEther("0.1") }))
      .to.be.revertedWith("insufficient ETH");
  });

  it("TC-11 NEG only verifier can record milestones, and only in order", async () => {
    await create(1000); await fund();
    await expect(tp.connect(stranger).recordMilestone(1, Status.Dispatched, "x")).to.be.reverted;
    await expect(tp.connect(verifier).recordMilestone(1, Status.Delivered, "x")).to.be.revertedWith("must be Dispatched");
  });

  it("TC-12 NEG buyer cannot approve own payment (separation of duties)", async () => {
    await create(6000); await fund(); await toDelivered();
    await tp.grantRole(await tp.APPROVER_ROLE(), buyer.address);
    await expect(tp.connect(buyer).approveRelease(1)).to.be.revertedWith("separation of duties");
  });

  it("TC-13 NEG same approver cannot approve twice", async () => {
    await create(6000); await fund(); await toDelivered();
    await tp.connect(appr1).approveRelease(1);
    await expect(tp.connect(appr1).approveRelease(1)).to.be.revertedWith("already approved");
  });

  it("TC-14 NEG release before delivery and double release both revert", async () => {
    await create(1000); await fund();
    await expect(tp.releasePayment(1)).to.be.revertedWith("not delivered");
    await toDelivered(); await tp.releasePayment(1);
    await expect(tp.releasePayment(1)).to.be.revertedWith("not delivered");
  });

  it("TC-15 NEG non-financier cannot fund financing; wrong amount reverts", async () => {
    await create(1000); await fund();
    await tp.connect(supplier).requestFinancing(1);
    await expect(tp.connect(stranger).fundFinancing(1, { value: 1 })).to.be.reverted;
    await expect(tp.connect(financier).fundFinancing(1, { value: 1 })).to.be.revertedWith("send exact advance");
  });

  it("TC-16 NEG withdraw with empty balance reverts; refund blocked after delivery", async () => {
    await expect(tp.connect(stranger).withdraw()).to.be.revertedWith("nothing to withdraw");
    await create(1000); await fund(); await toDelivered();
    await time.increaseTo(deadline + 10);
    await expect(tp.connect(buyer).claimRefund(1)).to.be.revertedWith("not refundable");
  });
});
