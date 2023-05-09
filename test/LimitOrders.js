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
    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.ARBITRUM_NET_API_URL,
            blockNumber: 44832616
          }
        }
      ]
    });
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
      "0xC36442b4a4522E871399CD717aBDD847Ab11FE88", // UNI V3 NFT Manager
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

    const markPrice = await optionScalp.getMarkPrice();

    expect(markPrice).to.eq(1000000000);

    const collateral = BigNumber.from('3000000000');

    const tick0 = -204000;
    const tick1 = tick0 + 10;

    console.log("Ticks: + ", tick0, tick1);

    // (1.0001 ** (-204000)) * (10 ** 12) = 1383

    await limitOrders.connect(user1).createOpenOrder(optionScalp.address, true, "5000000000", 4, collateral, tick0, tick1, {gasLimit: 4000000});

    // Bot tries to create order but price hasn't moved and Uniswap NFT order hasn't been filled
    await expect(limitOrders.connect(user2).fillOpenOrder(0)).to.be.revertedWith('Not filled as expected');

    // Callstatic try cancel order
    await limitOrders.connect(user1).callStatic.cancelOpenOrder(0);

    const bf5UsdcBalance = await usdc.balanceOf(bf5Address);
    await usdc.connect(bf5).approve(uniV3Router.address, bf5UsdcBalance);

    expect(bf5UsdcBalance).to.eq(2440414348267);

    await uniV3Router.connect(bf5).exactInputSingle({
      tokenIn: usdc.address,
      tokenOut: weth.address,
      fee: 500,
      recipient: bf5Address,
      deadline: "999999999999999999999999",
      amountIn: bf5UsdcBalance,
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });

    console.log("Uniswap");

    // Bot is triggered
    await limitOrders.connect(user2).fillOpenOrder(0);

    const position = await optionScalp.scalpPositions(1);
    console.log(position);
    expect(position['isOpen']).to.eq(true);
    expect(position['isShort']).to.eq(true);
    expect(position['size']).to.eq('5000000000');
    expect(position['amountBorrowed']).to.eq('5000000000000000000');
    expect(position['entry']).to.eq('722682176087564233');
    expect(position['margin']).to.eq('2972500000');
    expect(position['premium']).to.eq('25000000');
    expect(position['amountOut']).to.eq('6918670704');
  });

  it("user 1 closes the short scalp position using a limit order", async function () {
    const tick0 = -204100;
    const tick1 = tick0 + 10;

    console.log("Ticks: + ", tick0, tick1);

    // (1.0001 ** (-204100)) * (10 ** 12) = 1369

    // Create an order to close the position
    await limitOrders.connect(user1).createCloseOrder(optionScalp.address, 1, tick0, tick1);

    // Bot tries to close the position but price hasn't moved and Uniswap NFT order hasn't been filled
    await expect(limitOrders.connect(user2).fillCloseOrder(1)).to.be.revertedWith('Not filled as expected');

    // Bot tries to cancel the order
    await limitOrders.connect(user1).callStatic.cancelCloseOrder(1);

    // Price goes down
    const bf5WethBalance = await weth.balanceOf(bf5Address);
    await weth.connect(bf5).approve(uniV3Router.address, bf5WethBalance);

    expect(bf5WethBalance).to.eq("1825577554431309211987");

    const swapParams = {
      tokenIn: weth.address,
      tokenOut: usdc.address,
      fee: 500,
      recipient: bf5Address,
      deadline: "999999999999999999999999",
      amountIn: bf5WethBalance,
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    };

    const swapped = await uniV3Router.connect(bf5).callStatic.exactInputSingle(swapParams);

    await uniV3Router.connect(bf5).exactInputSingle(swapParams);

    console.log("Uniswap");

    console.log("Swapped " + swapped);

    const price = swapped.mul("100000000000000000000").div(bf5WethBalance);

    await priceOracle.updateUnderlyingPrice(price);

    const isLiquidatable = await optionScalp.isLiquidatable(1);
    expect(isLiquidatable).to.eq(false);

    // Try emergency withdraw nft
    const closeOrder = await limitOrders.callStatic.closeOrders(1);
    const positionId = closeOrder['positionId'];

    await optionScalp.callStatic.emergencyWithdrawNFTs([positionId]);

    // Even if there is a limit order it is still possible to close the position (by user or liquidation)

    // Bot can close using fillCloseOrder
    await limitOrders.connect(user2).callStatic.fillCloseOrder(1);

    // Kepper can also just call closePosition()
    await optionScalp.connect(user2).closePosition(1);

    const isActive = await limitOrders.isCloseOrderActive(1);
    expect(isActive).to.eq(false);

    console.log("Other users tries to call close but it has been already closed");
    await expect(optionScalp.connect(user2).callStatic.closePosition(1)).to.be.revertedWith("Invalid position ID");

    console.log("Owner tries to call close");
    await expect(optionScalp.connect(user1).callStatic.closePosition(1)).to.be.revertedWith("Invalid position ID");
  });
});
