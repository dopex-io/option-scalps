const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Option Perp", function() {
  let signers;
  let owner;

  let usdc;
  let weth;
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

    await weth.connect(b50).transfer(user1.address, ethers.utils.parseEther("200.0"));
    await usdc.connect(bf5).transfer(user1.address, "100000000000");

    await b50.sendTransaction({
      to: user1.address,
      value: ethers.utils.parseEther("100.0")
    });
  });
});