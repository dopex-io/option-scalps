const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Option scalp", function() {
  let signers;
  let owner;

  let usdc;
  let weth;
  let quoteLp;
  let baseLp;
  let uniV3Router;
  let priceOracle;
  let volatilityOracle;
  let optionPricing;
  let optionScalp;
  let b50;
  let bf5;
  let b50Address;
  let bf5Address;

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
    user3 = signers[4];
  });

  it("should deploy option scalp with oracles", async function() {
    await network.provider.request({
        method: "hardhat_reset",
        params: [
          {
            forking: {
              jsonRpcUrl: process.env.ARBITRUM_NET_API_URL,
              blockNumber: 69527274,
            },
          },
        ],
    });

    // USDC
    usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
    // WETH
    weth = await ethers.getContractAt("contracts/interface/IWETH9.sol:IWETH9", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    // Uni v3 router
    uniV3Router = await ethers.getContractAt("contracts/interface/IUniswapV3Router.sol:IUniswapV3Router", "0xE592427A0AEce92De3Edee1F18E0157C05861564");
    // Price oracle
    priceOracle = await ethers.getContractAt("contracts/mock/MockPriceOracle.sol:MockPriceOracle", "0x19e6eE4C2cBe7Bcc4cd1ef0BCF7e764fECe23cC6");
    // Volatility oracle
    const VolatilityOracle = await ethers.getContractFactory("VolatilityOracleSimple");
    volatilityOracle = await VolatilityOracle.deploy();
    // Option pricing
    const OptionPricing = await ethers.getContractFactory("OptionPricingSimple");
    optionPricing = await OptionPricing.deploy(1000, 1);

    // Option scalp
    const OptionScalp = await ethers.getContractFactory("OptionScalp");
    optionScalp = await OptionScalp.deploy(
      weth.address,
      usdc.address,
      optionPricing.address,
      volatilityOracle.address,
      priceOracle.address,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      "0xa028B56261Bb1A692C06D993c383c872B51AfB33", // GMX HELPER
      "10000000", // $10
      "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13" // Insurance fund
    );

    // Base LP
    baseLp = (await ethers.getContractFactory("ScalpLP")).attach((await optionScalp.baseLp()));

    // Quote LP
    quoteLp = (await ethers.getContractFactory("ScalpLP")).attach((await optionScalp.quoteLp()));

    console.log("deployed option scalp:", optionScalp.address);
  });

  it("distribute funds to user0, user1, user2 and user3", async function() {
    // Transfer USDC and WETH to our address from another impersonated address
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0xE2F35B376461E7FDd2f2E45248E4c3cD9626A933"],
    });

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0x9fc3b6191927b044ef709addd163b15c933ee205"],
    });

    b50Address = "0xE2F35B376461E7FDd2f2E45248E4c3cD9626A933";
    bf5Address = "0x9fc3b6191927b044ef709addd163b15c933ee205";

    b50 = await ethers.provider.getSigner(
      b50Address
    );

    bf5 = await ethers.provider.getSigner(
      bf5Address
    );

    await weth.connect(b50).transfer(user0.address, ethers.utils.parseEther("10.0"));
    await usdc.connect(bf5).transfer(user0.address, "10000000000");

    await weth.connect(b50).transfer(user1.address, ethers.utils.parseEther("10.0"));
    await usdc.connect(bf5).transfer(user1.address, "10000000000");

    await b50.sendTransaction({
        to: user0.address,
        value: ethers.utils.parseEther("5.0")
    });
  });

  it("user 0 deposits", async function() {
    await usdc.connect(user0).approve(optionScalp.address, "10000000000");
    await weth.connect(user0).approve(optionScalp.address, ethers.utils.parseEther("10.0"));

    await expect(optionScalp.connect(user0).deposit(true, "100000000000000000000000")).to.be.revertedWith("ERC20: transfer amount exceeds balance");

    console.log((await usdc.balanceOf(user0.address)));
    console.log((await weth.balanceOf(user0.address)));

    await optionScalp.connect(user0).deposit(true, "10000000000");
    await optionScalp.connect(user0).deposit(false, ethers.utils.parseEther("10.0"));
  });

  it("user 0 withdraws half", async function() {
    const scalpLpAddress = await optionScalp.connect(user0).quoteLp();
    quoteLp = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", scalpLpAddress);
    const balance = await quoteLp.balanceOf(user0.address);
    expect(balance).to.eq("10000000000");

    // Allowance is required
    await quoteLp.connect(user0).approve(optionScalp.address, "1000000000000000000000000000000000");

    await expect(optionScalp.connect(user0).withdraw(true, "10000000000000")).to.be.revertedWith('Not enough available assets to satisfy withdrawal');

    const startQuoteBalance = await usdc.balanceOf(user0.address);
    await optionScalp.connect(user0).withdraw(true, balance.div(2));
    const endQuoteBalance = await usdc.balanceOf(user0.address);

    const quoteOut = endQuoteBalance.sub(startQuoteBalance);
    expect(quoteOut).to.eq("5000000000");
  });

  it("user 1 opens a short scalp position, eth drops, position is closed", async function() {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq('10000000000');

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(true, "500000000000", 0, "20000000"); // 5000$ long

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq('9976221261');

    const amountPaid = startQuoteBalance.sub(quoteBalance);
    expect(amountPaid).to.eq("23778739"); // 20$ of margin + 1.27$ of premium + 2.5$ of fees
  });
});