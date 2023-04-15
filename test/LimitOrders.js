const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Limit orders", function () {
  let signers;
  let owner;

  let limitOrders;
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
  let keeper;
  let erc721;

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
    user3 = signers[4];
  });

  it("should deploy option scalp", async function () {
    // USDC
    usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
    // WETH
    weth = await ethers.getContractAt("contracts/interface/IWETH9.sol:IWETH9", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    // Uni v3 router
    uniV3Router = await ethers.getContractAt("contracts/interface/IUniswapV3Router.sol:IUniswapV3Router", "0xE592427A0AEce92De3Edee1F18E0157C05861564");
    // Price oracle
    const PriceOracle = await ethers.getContractFactory("MockPriceOracle");
    priceOracle = await PriceOracle.deploy();
    // Volatility oracle
    const VolatilityOracle = await ethers.getContractFactory("MockVolatilityOracle");
    volatilityOracle = await VolatilityOracle.deploy();
    // Option pricing
    const OptionPricing = await ethers.getContractFactory("MockOptionPricing");
    optionPricing = await OptionPricing.deploy();

    const LimitOrders = await ethers.getContractFactory("LimitOrderManager");
    limitOrders = await LimitOrders.deploy([]);

    // Option scalp
    const OptionScalp = await ethers.getContractFactory("OptionScalp");
    optionScalp = await OptionScalp.deploy(
      weth.address,
      usdc.address,
      18,
      6,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      limitOrders.address, // Limit orders manager
      [
          "100000000000",  // $100.000
          "10000000000000",  // $10M
          optionPricing.address,
          volatilityOracle.address,
          priceOracle.address,
          "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13", // Insurance fund
          "10000000", // $10
          "5000000", // 0.05%
          "4000",  // $0.004
          "1" // 1 second
      ]
    );

    await limitOrders.addOptionScalps([optionScalp.address]);

    // Base LP
    baseLp = (await ethers.getContractFactory("ScalpLP")).attach(await optionScalp.baseLp());

    // Quote LP
    quoteLp = (await ethers.getContractFactory("ScalpLP")).attach(await optionScalp.quoteLp());

    // Keeper
    keeper = await (await ethers.getContractFactory("Keeper")).deploy();

    await optionScalp.addToContractWhitelist(keeper.address);

    console.log("deployed option scalp:", optionScalp.address);
  });

  it("distribute funds to user0, user1, user2 and user3", async function () {
    // Transfer USDC and WETH to our address from another impersonated address
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13"],
    });

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0x9bf54297d9270730192a83EF583fF703599D9F18"],
    });

    b50Address = "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13";
    bf5Address = "0x9bf54297d9270730192a83EF583fF703599D9F18";

    b50 = await ethers.provider.getSigner(b50Address);

    bf5 = await ethers.provider.getSigner(bf5Address);

    [user0, user1, user2, user3].map(async (user) => {
      await weth.connect(b50).transfer(user.address, ethers.utils.parseEther("10.0"));
      await usdc.connect(bf5).transfer(user.address, "10000000000");

      await b50.sendTransaction({
        to: user.address,
        value: ethers.utils.parseEther("10.0"),
      });
    });
  });

  it("user 0 deposits", async function () {
    await usdc.connect(user0).approve(optionScalp.address, "10000000000");
    await weth.connect(user0).approve(optionScalp.address, ethers.utils.parseEther("10.0"));

    await expect(optionScalp.connect(user0).deposit(user0.address, true, "100000000000000000000000")).to.be.revertedWith("ERC20: transfer amount exceeds balance");

    await optionScalp.connect(user0).deposit(user0.address, true, "10000000000");
    await optionScalp.connect(user0).deposit(user0.address, false, ethers.utils.parseEther("10.0"));

    await optionScalp.addToContractWhitelist(limitOrders.address);
  });

  it("user 1 opens a short scalp position using a limit order", async function () {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq("10000000000");

    await usdc.connect(user1).approve(limitOrders.address, "10000000000");

    const expiry = "999999999999999999999999999999999999"

    const markPrice = await optionScalp.getMarkPrice();

    expect(markPrice).to.eq(1000000000);

    const collateral = BigNumber.from('3000000000');

    const tick0 = Math.floor(Math.log("5000") / Math.log(1.0001));
    const tick1 = tick0 + 10;

    console.log("Ticks: + ", tick0, tick1);

    await limitOrders.connect(user1).createOrder(optionScalp.address, true, "5000000000", 0, collateral, tick0, tick1, expiry);

    // User 2 tries to fill order
    await expect(limitOrders.connect(user2).fillOrder(0)).to.be.revertedWith('Mark price must be lower than limit entry price');

    await priceOracle.updateUnderlyingPrice("890000000");

    await limitOrders.connect(user2).fillOrder(0);

    // Check position
    const scalpPosition = await optionScalp.scalpPositions(1);
    expect(scalpPosition.size).to.eq("5000000000");

    const scalpPositionMinter = await optionScalp.scalpPositionMinter();

    const ERC721 = await ethers.getContractFactory("ERC721");
    erc721 = await ERC721.attach(scalpPositionMinter);

    const owner = await erc721.ownerOf(1);
    expect(owner).to.eq(user1.address);

    const endQuoteBalance = await usdc.balanceOf(user1.address);

    const quoteOut = endQuoteBalance.sub(startQuoteBalance);
    expect(quoteOut).to.eq(collateral * -1);
  });
});
