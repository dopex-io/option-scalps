// CHANGE hardhat.config.js fork block number to 20412157 before to run this

const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Option Scalp | Uni V3 | GMX", function () {
  let signers;
  let owner;
  let userAddress;
  let user;
  let usdc;
  let weth;
  let priceOracle;
  let volatilityOracle;
  let uniswapFactory;
  let gmxRouter;
  let assetSwapper;
  let uniswapV2Router;
  let uniswapV3Router;
  let atlanticStraddle;
  let optionPricing;

  const MAX_UINT =
    "115792089237316195423570985008687907853269984665640564039457584007913129639935";

  const OPTION_PRICING = "0x2b99e3d67dad973c1b9747da742b7e26c8bdd67b";

  const EXPIRY = 1665972014;

  const toEther = (val) => BigNumber.from(10).pow(18).mul(val);

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];
  });

  it("should deploy atlantic straddle", async function () {
    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.ARBITRUM_RPC_URL,
            blockNumber: 20412157,
          },
        },
      ],
    });

    // Impersonate a USDC holder
    userAddress = "0xA0894A415c4F246CE95BaE718849579c099Cc1d2";
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [userAddress],
    });
    user = await ethers.provider.getSigner(userAddress);

    // USDC
    usdc = await ethers.getContractAt(
      "USDC",
      "0xff970a61a04b1ca14834a43f5de4533ebddb5cc8"
    );
    weth = await ethers.getContractAt(
      "WETH",
      "0x82af49447d8a07e3bd95bd0d56f35241523fbab1"
    );

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

    const UniswapFactory = await ethers.getContractFactory("UniswapV2Factory");
    uniswapFactory = await UniswapFactory.deploy(owner.address);

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
    // Atlantic Straddle
    const AtlanticStraddle = await ethers.getContractFactory(
      "AtlanticStraddle"
    );
    atlanticStraddle = await AtlanticStraddle.deploy(
      "Atlantic Straddles",
      "AS",
      [
        usdc.address,
        weth.address,
        assetSwapper.address,
        priceOracle.address,
        volatilityOracle.address,
        OPTION_PRICING,
        "0x55594cCe8cC0014eA08C49fd820D731308f204c1",
      ]
    );

    await atlanticStraddle.setAssetSwapperAllowance(
      usdc.address,
      MAX_UINT,
      true
    );
    await atlanticStraddle.setAssetSwapperAllowance(
      weth.address,
      MAX_UINT,
      true
    );
  });

  it("should deposit successfully", async () => {
    const amount = 10000 * 10 ** 6;
    await usdc.connect(user).approve(atlanticStraddle.address, MAX_UINT);
    await atlanticStraddle.connect(user).deposit(amount, true, userAddress);

    expect((await atlanticStraddle.epochData(1)).usdDeposits).equals(amount);
  });

  it("should bootstrap successfully", async () => {
    await atlanticStraddle.bootstrap(EXPIRY);
    expect(await atlanticStraddle.currentEpoch()).equals(1);
  });

  it("should purchase successfully using uniswap v3", async () => {
    await atlanticStraddle
      .connect(user)
      .purchase(toEther(1), 0, 1, userAddress);
  });

  it("should purchase successfully using gmx", async () => {
    await atlanticStraddle
      .connect(user)
      .purchase(toEther(1), 0, 2, userAddress);
  });
});
