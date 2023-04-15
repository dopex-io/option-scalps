const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Option scalp", function () {
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
  let keeper;
  let limitOrders;

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
      limitOrders.address, //  Limit orders
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
  });

  it("user 0 withdraws half", async function () {
    const scalpLpAddress = await optionScalp.connect(user0).quoteLp();
    quoteLp = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", scalpLpAddress);
    const balance = await quoteLp.balanceOf(user0.address);
    expect(balance).to.eq("10000000000");

    // Allowance is required
    await quoteLp.connect(user0).approve(optionScalp.address, "1000000000000000000000000000000000");

    await expect(optionScalp.connect(user0).withdraw(true, "10000000000000")).to.be.revertedWith("Not enough available assets to satisfy withdrawal");

    const startQuoteBalance = await usdc.balanceOf(user0.address);
    await optionScalp.connect(user0).withdraw(true, balance.div(2));
    const endQuoteBalance = await usdc.balanceOf(user0.address);

    const quoteOut = endQuoteBalance.sub(startQuoteBalance);
    expect(quoteOut).to.eq("5000000000");
  });

  it("user 1 opens a short scalp position, eth drops, position is closed", async function () {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq("10000000000");

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(true, "5000000000", 0, "20000000", "0"); // 5000$ long

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq("9952500000");

    const amountPaid = startQuoteBalance.sub(quoteBalance);
    expect(amountPaid).to.eq("47500000"); // 20$ of margin + 25$ of premium + 2.5$ of fees

    await weth.connect(b50).deposit({ value: ethers.utils.parseEther("260.0") });
    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("1000.0"));

    let actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("128555210800"); // $1285.55

    await uniV3Router.connect(b50).exactInputSingle({
      tokenIn: weth.address,
      tokenOut: usdc.address,
      fee: 500,
      recipient: b50Address,
      deadline: "999999999999999999999999",
      amountIn: ethers.utils.parseEther("900.0"),
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq("9952500000");

    actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("125353431000"); // $1253.53

    // price drops from 1285.67 to 1253.53 = $32.14
    // size was $5000 so positions is 5000 / 1285.55 = 3.88, expected profit is 3.88 * 32.14 = $124.70

    expect(await optionScalp.isLiquidatable(1)).to.eq(false);

    await network.provider.send("evm_increaseTime", [10]);

    await optionScalp.connect(user1).closePosition(1);

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq("10091978397");

    const profit = quoteBalance.sub(startQuoteBalance);

    // $124.70 - 25$ of premium - 2.5$ of fees = $97.2
    // it is slightly different because we move the price too when we enter and close the position
    // so 1285 and 1253 are not exactly our correct entry and exit price
    expect(profit).to.eq("91978397"); // $91.97
  });

  it("user 1 opens a short scalp position, eth pumps, position is closed", async function () {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq("10091978397");

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(true, "5000000000", 0, "500000000", "0"); // 5000$ short

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq("9564478397");

    const amountPaid = startQuoteBalance.sub(quoteBalance);
    expect(amountPaid).to.eq("527500000"); // 500$ of margin + 25$ of premium + 2.5$ of fees

    const b50UsdcBalance = await usdc.balanceOf(b50Address);
    await usdc.connect(b50).approve(uniV3Router.address, b50UsdcBalance);
    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("1000000000.0"));
    await usdc.connect(bf5).approve(uniV3Router.address, "550000000000");

    let actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("125353162800"); // $1253.53

    await uniV3Router.connect(b50).exactInputSingle({
      tokenIn: usdc.address,
      tokenOut: weth.address,
      fee: 500,
      recipient: b50Address,
      deadline: "999999999999999999999999",
      amountIn: "250000000000",
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });

    actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("126099007200"); // $1260.99

    await priceOracle.updateUnderlyingPrice("126099007200");

    // price pumps from 1253.53 to 1260.99 = -$7.46
    // size was $5000 so positions is 5000 / 1253.53 = 3.98873581, expected profit is 3.98873581 * -7.46 = -$29.75

    expect(await optionScalp.isLiquidatable(2)).to.eq(false);

    await network.provider.send("evm_increaseTime", [10]);

    await optionScalp.connect(user1).closePosition(2);

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq("10029186890");

    const profit = quoteBalance.sub(startQuoteBalance);

    // - $30 of pnl - 25$ of premium - 2.5$ of fees = $57.5
    // it is slightly different because we move the price too when we enter and close the position
    // so 1253.81 and 1260.99 are not exactly our correct entry and exit price
    expect(profit).to.eq("-62791507"); // $62.79
  });

  it("user 1 opens a long scalp position, eth pumps, position is closed", async function () {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq("10029186890");

    let actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("126114886400"); // $1261.14

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(false, "5000000000", 0, "500000000", "130563345200");

    await usdc.connect(bf5).approve(uniV3Router.address, "1500000000000");

    await uniV3Router.connect(bf5).exactInputSingle({
      tokenIn: usdc.address,
      tokenOut: weth.address,
      fee: 500,
      recipient: b50Address,
      deadline: "999999999999999999999999",
      amountIn: "1500000000000",
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });

    actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("130563345200"); // $1305.56

    await priceOracle.updateUnderlyingPrice("130563344300");

    // price pumps from 1261.14 to 1305.63 = -$44.49
    // size was $5000 so positions is 5000 / 1261.14 = 3.96, expected profit is 3.96 * 44.49 = $176.18

    await network.provider.send("evm_increaseTime", [10]);

    await optionScalp.connect(user1).closePosition(3);

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq("10177349876");

    const profit = quoteBalance.sub(startQuoteBalance);

    // $176.18 of pnl - 25$ of premium - 2.5$ of fees = $148.68
    // it is slightly different because we move the price too when we enter and close the position
    // so 1261.14 and 1305.63 are not exactly our correct entry and exit price
    expect(profit).to.eq("148162986"); // $148.16
  });

  it("user 1 opens a long scalp position, eth drops, position is closed", async function () {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq("10177349876");

    let actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("130543299900"); // $1305.43

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(false, "5000000000", 0, "2500000000", "130786171127");

    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("900.0"));

    await uniV3Router.connect(b50).exactInputSingle({
      tokenIn: weth.address,
      tokenOut: usdc.address,
      fee: 500,
      recipient: b50Address,
      deadline: "999999999999999999999999",
      amountIn: ethers.utils.parseEther("800.0"),
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });

    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("900.0"));

    actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("127574029900"); // $1275.74

    await priceOracle.updateUnderlyingPrice("127574029900");

    // price pumps from 1305.43 to 1275.74 = -$29.69
    // size was $5000 so positions is 5000 / 1305.43 = 3.83, expected profit is 3.83 * -29.69 = -$113.71

    await network.provider.send("evm_increaseTime", [10]);

    await optionScalp.connect(user1).closePosition(4);

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq("10036438021");

    const profit = quoteBalance.sub(startQuoteBalance);

    // - $113.71 of pnl - 25$ of premium - 2.5$ of fees = - $141.21
    // it is slightly different because we move the price too when we enter and close the position
    // so 1261.14 and 1305.63 are not exactly our correct entry and exit price
    expect(profit).to.eq("-140911855"); // $140.91
  });

  it("user 1 opens a short scalp position, eth pumps, position is liquidated and margin is enough", async function () {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq("10036438021");

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(true, "5000000000", 0, "32000000", "0"); // 5000$ short

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq("9982341557");

    const amountPaid = startQuoteBalance.sub(quoteBalance);
    expect(amountPaid).to.eq("54096464"); // 32$ of margin + 19.59$ of premium + 2.5$ of fees

    const b50UsdcBalance = await usdc.balanceOf(b50Address);
    await usdc.connect(b50).approve(uniV3Router.address, b50UsdcBalance);
    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("1000000000.0"));
    await usdc.connect(bf5).approve(uniV3Router.address, "550000000000");

    let actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("127546184400"); // $1275.46

    await uniV3Router.connect(b50).exactInputSingle({
      tokenIn: usdc.address,
      tokenOut: weth.address,
      fee: 500,
      recipient: b50Address,
      deadline: "999999999999999999999999",
      amountIn: "250000000000",
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });

    actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("128218529500"); // $1282.18

    // price pumps from 1275.46 to 1282.18 = -$6.72
    // size was $5000 so positions is 5000 / 1275.46 = 3.92, expected profit is 3.92 * -6.72 = -$26.34

    await priceOracle.updateUnderlyingPrice("128218539300");

    await network.provider.send("evm_increaseTime", [10]);

    await optionScalp.connect(user1).closePosition(5);

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq("9982341557");

    const profit = quoteBalance.sub(startQuoteBalance);

    // -32$ margin - 19.95$ of premium - 2.5$ of fees = $54.45
    expect(profit).to.eq("-54096464");
  });

  it("user 1 opens a long scalp position, eth drops, position is liquidated and margin is not enough", async function () {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq("9982341557");

    let actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("128228284900"); // $1282.28

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(false, "5000000000", 0, "120000000", "129249311600");

    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("900.0"));

    await uniV3Router.connect(b50).exactInputSingle({
      tokenIn: weth.address,
      tokenOut: usdc.address,
      fee: 500,
      recipient: b50Address,
      deadline: "999999999999999999999999",
      amountIn: ethers.utils.parseEther("800.0"),
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });

    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("900.0"));

    actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("125249311600"); // $1252.49

    // price pumps from 1282.28 to 1252.49 = -$29.79
    // size was $5000 so positions is 5000 / 1282.28 = 3.89, expected profit is 3.89 * -29.79 = -$115.81

    await priceOracle.updateUnderlyingPrice("125249327600");

    await network.provider.send("evm_increaseTime", [10]);

    await optionScalp.closePosition(6);

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq("9840343597");

    const profit = quoteBalance.sub(startQuoteBalance);

    // - $120 of margin - 19.49 of premium - 2.5$ of fees = - $141.99
    expect(profit).to.eq("-141997960"); // $141.99
  });

  it("user 1 opens a short scalp position, eth pumps, position is liquidated and margin is not enough", async function () {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq("9840343597");

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(true, "5000000000", 0, "30000000", "0"); // 5000$ short

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq("9787883411");

    const amountPaid = startQuoteBalance.sub(quoteBalance);
    expect(amountPaid).to.eq("52460186"); // 30$ of margin + 19.96$ of premium + 2.5$ of fees

    const b50UsdcBalance = await usdc.balanceOf(b50Address);
    await usdc.connect(b50).approve(uniV3Router.address, b50UsdcBalance);
    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("1000000000.0"));
    await usdc.connect(bf5).approve(uniV3Router.address, "550000000000");

    let actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("125221355200"); // $1252.21

    await uniV3Router.connect(b50).exactInputSingle({
      tokenIn: usdc.address,
      tokenOut: weth.address,
      fee: 500,
      recipient: b50Address,
      deadline: "999999999999999999999999",
      amountIn: "250000000000",
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });

    actualPrice = (
      await uniV3Router.connect(b50).callStatic.exactInputSingle({
        tokenIn: weth.address,
        tokenOut: usdc.address,
        fee: 500,
        recipient: b50Address,
        deadline: "999999999999999999999999",
        amountIn: ethers.utils.parseEther("1.0"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
    ).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("125952367300"); // $1259.52

    // price pumps from 1252.21 to 1259.52 = -$7.31
    // size was $5000 so positions is 5000 / 1252.21 = 3.99, expected profit is 3.99 * -7.31 = -$29.16

    await priceOracle.updateUnderlyingPrice("125952385100");

    await network.provider.send("evm_increaseTime", [10]);

    let positions = await keeper.getCloseablePositions(0, 10, optionScalp.address);
    positions = positions.filter((positionId) => !positionId.isZero());
    await keeper.closePositions(positions, optionScalp.address);

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq('9787883411');

    const profit = quoteBalance.sub(startQuoteBalance);

    // -30$ margin - 19.96$ of premium - 2.5$ of fees = $52.46
    expect(profit).to.eq("-52460186");
  });

  it("user 1 opens a long scalp position, eth drops, position is liquidated and margin is enough", async function() {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq('9787883411');

    let actualPrice = (await uniV3Router.connect(b50).callStatic.exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: usdc.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("1.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    )).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("125968228800"); // $1259.68

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(false, "5000000000", 0, "90000000", "126268720400");

    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("700.0"));

    await uniV3Router.connect(b50).exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: usdc.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("500.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    );

    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("1.0"));

    actualPrice = (await uniV3Router.connect(b50).callStatic.exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: usdc.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("1.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    )).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("124168720400"); // $1241.68

    // price pumps from 1259.68 to 1241.68 = -$18
    // size was $5000 so positions is 5000 / 1259.68 = 3.96, expected profit is 3.96 * -18 = -$71.28

    expect((await optionScalp.getLiquidationPrice(8))).to.eq("1261027749");

    await priceOracle.updateUnderlyingPrice("124168720400");

    await network.provider.send("evm_increaseTime", [10]);

    await optionScalp.closePosition(8);

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq('9675534641');

    const profit = quoteBalance.sub(startQuoteBalance);

    // - $90 of margin - 19.84 of premium - 2.5$ of fees
    expect(profit).to.eq("-112348770"); // $172.34
  });

  it("user 0 withdraws portion of eth deposit with pnl", async function() {
    const startBaseBalance = await weth.balanceOf(user0.address);

    await baseLp.connect(user0).approve(optionScalp.address, ethers.utils.parseEther("3.0"));
    await optionScalp.connect(user0).withdraw(false, ethers.utils.parseEther("3.0"));

    const endBaseBalance = await weth.balanceOf(user0.address);

    const difference = endBaseBalance.sub(startBaseBalance);

    expect(difference).to.eq("3021176971622294804");

  });

  it("user 0 withdraws portion of usd deposit with pnl", async function() {
    const startQuoteBalance = await usdc.balanceOf(user0.address);

    await quoteLp.connect(user0).approve(optionScalp.address, "2000000000");
    await optionScalp.connect(user0).withdraw(true, "2000000000");

    const endQuoteBalance = await usdc.balanceOf(user0.address);

    const difference = endQuoteBalance.sub(startQuoteBalance);

    expect(difference).to.eq("2031289095");

  });

  it("user 1 opens a long scalp position and user 0 cannot withdraw more than available liquidity", async function() {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq('9675534641');

    let actualPrice = (await uniV3Router.connect(b50).callStatic.exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: usdc.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("1.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    )).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("124154866100"); // $1241.54

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(false, "1000000000", 0, "150000000", "124282270632");

    expect(await optionScalp.getLiquidationPrice(9)).to.eq("1242676706");

    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("700.0"));

    await uniV3Router.connect(b50).exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: usdc.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("15.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    );

    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("1.0"));

    actualPrice = (await uniV3Router.connect(b50).callStatic.exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: usdc.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("1.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    )).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("124105285300"); // $1241.05

    // price pumps from 1241.54 to 1241.05 = -$0.49
    // size was $5000 so positions is 5000 / 1241.54 = 4.027, expected profit is 4.027 * -0.49 = -$-1.97323

    await priceOracle.updateUnderlyingPrice("124105285300");

    await quoteLp.connect(user0).approve(optionScalp.address, "3000000000");
    await expect(optionScalp.connect(user0).withdraw(true, "3000000000")).to.be.revertedWith("Not enough available assets to satisfy withdrawal");
  });

  it("user 1 closes long scalp position and user 0 withdraws remaining available liquidity", async function() {
    await optionScalp.connect(user1).closePosition(9);

    await optionScalp.connect(user0).withdraw(true, "3000000000");
  });

  it("update max size and max open interest", async function() {
    await optionScalp.updateConfig([
        "10000000000",  // $10k
        "12000000000",  // $12k
         optionPricing.address,
         volatilityOracle.address,
         priceOracle.address,
         "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13", // Insurance fund
         "10000000", // $10
         "5000000", // 0.05%
         "5000000",  // $5
         "60" // 1 minute
    ]);
  });

  it("user 1 cannot open position larger than max size", async function() {
      await expect(optionScalp.connect(user1).openPosition(true, "15000000000", 0, "150000000", "0")).to.be.revertedWith("Position exposure is too high");
  });

  it("user 1 cannot open position when exceeding max open interest", async function() {
      await optionScalp.updateConfig([
            "10000000000",  // $10k
            "1000000000",  // $1k
             optionPricing.address,
             volatilityOracle.address,
             priceOracle.address,
             "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13", // Insurance fund
             "10000000", // $10
             "5000000", // 0.05%
             "4000",  // $0.004
             "60" // 1 minute
      ]);
      await expect(optionScalp.connect(user1).openPosition(true, "1500000000", 0, "150000000", "0")).to.be.revertedWith("OI is too high");
  });

  it("user 1 can open position with leverage 1x", async function() {
       await optionScalp.connect(user1).openPosition(true, "150000000", 0, "150000000", "0");
       expect((await optionScalp.getLiquidationPrice(10))).to.eq(1242036106);
  });

  it("get positions of user 1", async function() {
      // if we burn tokens we find nothing here
      const positions = await optionScalp.connect(user1).positionsOfOwner(user1.address);
      expect(positions[0]).to.eq(10);
  });

  it("pre emergency withdraw", async function() {
      const usdcScalpBalance = await usdc.balanceOf(optionScalp.address);
      const wethScalpBalance = await weth.balanceOf(optionScalp.address);
      expect(usdcScalpBalance).to.eq("309137748");
      expect(wethScalpBalance).to.eq("6933632223767943623");

      const owner = await optionScalp.owner();

      const usdcOwnerBalance = await usdc.balanceOf(owner);
      const wethOwnerBalance = await weth.balanceOf(owner);
      expect(usdcOwnerBalance).to.eq("0");
      expect(wethOwnerBalance).to.eq("0");

      await optionScalp.emergencyWithdraw([weth.address, usdc.address], false);
  });

  it("after emergency withdraw", async function() {
      const usdcScalpBalance = await usdc.balanceOf(optionScalp.address);
      const wethScalpBalance = await weth.balanceOf(optionScalp.address);
      expect(usdcScalpBalance).to.eq("0");
      expect(wethScalpBalance).to.eq("0");

      const owner = await optionScalp.owner();

      const usdcOwnerBalance = await usdc.balanceOf(owner);
      const wethOwnerBalance = await weth.balanceOf(owner);
      expect(usdcOwnerBalance).to.eq("309137748");
      expect(wethOwnerBalance).to.eq("6933632223767943623");
  });
});
