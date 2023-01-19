const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Option Scalps", function () {
  let signers;
  let owner;
  let usdc;
  let weth;
  let priceOracle;
  let volatilityOracle;
  let uniswapFactory;
  let assetSwapper;
  let uniswapV2Router;
  let uniswapV3Router;
  let gmxRouter;
  let optionScalp;

  const MAX_UINT =
    "115792089237316195423570985008687907853269984665640564039457584007913129639935";

  const OPTION_PRICING = "0x2b99e3d67dad973c1b9747da742b7e26c8bdd67b";
  const GMX_HELPER = "0xa028B56261Bb1A692C06D993c383c872B51AfB33", // GMX HELPER

  // 10th March 2022 8 AM UTC
  const EXPIRY = 1646899200;

  const toEther = (val) => BigNumber.from(10).pow(18).mul(val);

  const toDecimals = (val, decimals) =>
    BigNumber.from(10).pow(decimals).mul(val);

  const timeTravel = async (seconds) => {
    await network.provider.send("evm_increaseTime", [seconds]);
    await network.provider.send("evm_mine", []);
  };

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
  });

  it("should deploy option scalp", async function () {
    // USDC
    const USDC = await ethers.getContractFactory("USDC");
    usdc = await USDC.deploy();
    // WETH
    const WETH = await ethers.getContractFactory("WETH");
    weth = await WETH.deploy();
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
    // Uniswap factory
    const UniswapFactory = await ethers.getContractFactory("UniswapV2Factory");
    uniswapFactory = await UniswapFactory.deploy(owner.address);

    // WETH-USDC pair
    await uniswapFactory.createPair(weth.address, usdc.address);

    // Uniswap v2 router
    const UniswapV2Router = await ethers.getContractFactory(
      "UniswapV2Router02"
    );
    uniswapV2Router = await UniswapV2Router.deploy(
      uniswapFactory.address,
      weth.address
    );
    // Uniswap v3 router
    uniswapV3Router = await ethers.getContractAt(
      "IUniswapV3Router",
      "0xE592427A0AEce92De3Edee1F18E0157C05861564"
    );
    // Gmx router
    gmxRouter = await ethers.getContractAt(
      "IGmxRouter",
      "0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064"
    );
    
    // Asset swapper
    const AssetSwapper = await ethers.getContractFactory("AssetSwapper");

    assetSwapper = await AssetSwapper.deploy(
      uniswapV2Router.address,
      uniswapV3Router.address,
      gmxRouter.address,
      weth.address
    );
    // Option Scalp
    const OptionScalp = await ethers.getContractFactory(
      "OptionScalp"
    );
    // address _base,
    // address _quote,
    // address _optionPricing,
    // address _volatilityOracle,
    // address _priceOracle,
    // address _gmxRouter,
    // address _gmxHelper,
    // uint _minimumMargin
    optionScalp = await OptionScalp.deploy(
        weth.address,
        usdc.address,
        OPTION_PRICING,
        volatilityOracle.address,
        priceOracle.address,
        gmxRouter.address,
        GMX_HELPER,
        "10000000", // $10
    );

    const wethBalance = await weth.balanceOf(owner.address);
    const usdcBalance = await usdc.balanceOf(owner.address);

    expect(wethBalance).to.equal("100000000000000000000000000000");
    expect(usdcBalance).to.equal("10000000000000000000");
  });
});