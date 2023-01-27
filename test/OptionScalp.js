const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Option scalp", function() {
  let signers;
  let owner;

  let usdc;
  let weth;
  let scalpLp;
  let priceOracle;
  let volatilityOracle;
  let optionPricing;
  let optionScalp;
  let b50;
  let bf5;

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
    user3 = signers[4];
  });

  it("should deploy option scalp", async function() {
    // USDC
    usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
    // WETH
    weth = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    // Price oracle
    const PriceOracle = await ethers.getContractFactory("MockPriceOracle");
    priceOracle = await PriceOracle.deploy();
    // Volatility oracle
    const VolatilityOracle = await ethers.getContractFactory(
      "MockVolatilityOracle"
    );
    volatilityOracle = await VolatilityOracle.deploy();
    // Option pricing
    const OptionPricing = await ethers.getContractFactory("MockOptionPricing");
    optionPricing = await OptionPricing.deploy();

    // Option scalp
    const OptionScalp = await ethers.getContractFactory("OptionScalp");
    optionScalp = await OptionScalp.deploy(
      weth.address,
      usdc.address,
      optionPricing.address,
      volatilityOracle.address,
      priceOracle.address,
      "0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064", // GMX ROUTER
      "0xa028B56261Bb1A692C06D993c383c872B51AfB33", // GMX HELPER
      "10000000", // $10
    );

    console.log("deployed option scalp:", optionScalp.address);
  });

  it("distribute funds to user0, user1, user2 and user3", async function() {
    // Transfer USDC and WETH to our address from another impersonated address
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13"],
    });

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0x9bf54297d9270730192a83EF583fF703599D9F18"],
    });

    b50 = await ethers.provider.getSigner(
      "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13"
    );

    bf5 = await ethers.provider.getSigner(
      "0x9bf54297d9270730192a83EF583fF703599D9F18"
    );

    [user0, user1, user2, user3].map(async user => {
      await weth.connect(b50).transfer(user.address, ethers.utils.parseEther("10.0"));
      await usdc.connect(bf5).transfer(user.address, "10000000000");

      await b50.sendTransaction({
        to: user.address,
        value: ethers.utils.parseEther("10.0")
      });
    });
  });

  it("user 0 deposits", async function() {
    await usdc.connect(user0).approve(optionScalp.address, "10000000000");

    await expect(optionScalp.connect(user0).deposit("100000000000000000000000")).to.be.revertedWith("ERC20: transfer amount exceeds balance");

    await optionScalp.connect(user0).deposit("10000000000");
  });

  it("user 0 withdraws half", async function() {
    const scalpLpAddress = await optionScalp.connect(user0).scalpLp();
    scalpLp = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", scalpLpAddress);
    const balance = await scalpLp.balanceOf(user0.address);
    expect(balance).to.eq("10000000000");

    // Allowance is required
    await scalpLp.connect(user0).approve(optionScalp.address, "1000000000000000000000000000000000");

    await expect(optionScalp.connect(user0).withdraw("10000000000000")).to.be.revertedWith('Not enough available assets to satisfy withdrawal');

    const startQuoteBalance = await usdc.balanceOf(user0.address);
    await optionScalp.connect(user0).withdraw(balance.div(2));
    const endQuoteBalance = await usdc.balanceOf(user0.address);

    const quoteOut = endQuoteBalance.sub(startQuoteBalance);
    expect(quoteOut).to.eq("5000000000");
  });

  it("user 1 opens a $5000 short scalp position with 200$ of margin", async function() {
    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition("5000000000", 0, "20000000");
  });

  it("eth drops 10%, position is closed", async function() {
    await priceOracle.updateUnderlyingPrice("90000000000");
    const markPrice = await optionScalp.getMarkPrice();
    expect(markPrice).to.eq("90000000000");

    const startQuoteBalance = await usdc.balanceOf(user1.address);

    expect(startQuoteBalance).to.eq('9979975000');

    await optionScalp.connect(user1).closePosition(0);

    const endQuoteBalance = await usdc.balanceOf(user1.address);

    expect(endQuoteBalance).to.eq('10049478350');

    const profit = endQuoteBalance.sub(startQuoteBalance);

    expect(profit).to.eq("69503350"); // $69.50335
  });
});