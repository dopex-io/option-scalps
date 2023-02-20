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

  it("should deploy option scalp", async function() {
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
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      "0xa028B56261Bb1A692C06D993c383c872B51AfB33", // GMX HELPER
      "10000000", // $10
       "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13" // Insurace fund
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

    b50Address = "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13";
    bf5Address = "0x9bf54297d9270730192a83EF583fF703599D9F18";

    b50 = await ethers.provider.getSigner(
      b50Address
    );

    bf5 = await ethers.provider.getSigner(
      bf5Address
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
    await weth.connect(user0).approve(optionScalp.address, ethers.utils.parseEther("10.0"));

    await expect(optionScalp.connect(user0).deposit(true, "100000000000000000000000")).to.be.revertedWith("ERC20: transfer amount exceeds balance");

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
    expect(quoteBalance).to.eq('9952500000');

    const amountPaid = startQuoteBalance.sub(quoteBalance);
    expect(amountPaid).to.eq("47500000"); // 20$ of margin + 25$ of premium + 2.5$ of fees

    await weth.connect(b50).deposit({value: ethers.utils.parseEther("260.0")});
    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("1000.0"));

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

    expect(actualPrice).to.eq("128555210800"); // $1285.55

    await uniV3Router.connect(b50).exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: usdc.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("900.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    );

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq('9952500000');

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

    expect(actualPrice).to.eq("125353431000"); // $1253.53

    // price drops from 1285.67 to 1253.53 = $32.14
    // size was $5000 so positions is 5000 / 1285.55 = 3.88, expected profit is 3.88 * 32.14 = $124.70

    await optionScalp.connect(user1).closePosition(0);

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq('10092117978');

    const profit = quoteBalance.sub(startQuoteBalance);

    // $124.70 - 25$ of premium - 2.5$ of fees = $97.2
    // it is slightly different because we move the price too when we enter and close the position
    // so 1285 and 1253 are not exactly our correct entry and exit price
    expect(profit).to.eq("92117978"); // $92.11
  });

  it("user 1 opens a short scalp position, eth pumps, position is closed", async function() {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq('10092117978');

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(false, "500000000000", 0, "20000000"); // 5000$ long

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq('10044617978');

    const amountPaid = startQuoteBalance.sub(quoteBalance);
    expect(amountPaid).to.eq("47500000"); // 20$ of margin + 25$ of premium + 2.5$ of fees

    const b50UsdcBalance = await usdc.balanceOf(b50Address);
    await usdc.connect(b50).approve(uniV3Router.address, b50UsdcBalance);
    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("1000000000.0"));
    await usdc.connect(bf5).approve(uniV3Router.address, "150000000000");

    console.log("test");

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

    console.log('test');

    expect(actualPrice).to.eq("128555210800"); // $1285.55

    await uniV3Router.connect(b50).exactInputSingle(
        {
          tokenIn: usdc.address,
          tokenOut: weth.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: "150000000000",
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    );

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

    expect(actualPrice).to.eq("125353431000"); // $1253.53

    // price drops from 1285.67 to 1253.53 = $32.14
    // size was $5000 so positions is 5000 / 1285.55 = 3.88, expected profit is 3.88 * 32.14 = $124.70

    await optionScalp.connect(user1).closePosition(1);

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq('10092111377');

    const profit = quoteBalance.sub(startQuoteBalance);

    // $124.70 - 25$ of premium - 2.5$ of fees = $97.2
    // it is slightly different because we move the price too when we enter and close the position
    // so 1285 and 1253 are not exactly our correct entry and exit price
    expect(profit).to.eq("92111377"); // $92.11
  });

  it("user 1 opens a long scalp position, eth pumps, position is closed", async function() {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq('10004376749');

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(false, "5000000000", 0, "90000000");

    await usdc.connect(bf5).approve(uniV3Router.address, "1500000000000");

    await uniV3Router.connect(bf5).exactInputSingle(
        {
          tokenIn: usdc.address,
          tokenOut: weth.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: "1500000000000",
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    );

    await optionScalp.connect(user1).closePosition(2);

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq('10272372560');

    const profit = quoteBalance.sub(startQuoteBalance);

    expect(profit).to.eq("267995811"); // -$267.99
  });

  it("user 1 opens a long scalp position, eth drops, position is closed", async function() {
    const startQuoteBalance = await usdc.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq('10272372560');

    await usdc.connect(user1).approve(optionScalp.address, "10000000000");
    await optionScalp.connect(user1).openPosition(false, "5000000000", 0, "80000000");

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq('10192097560');

    await weth.connect(b50).approve(uniV3Router.address, ethers.utils.parseEther("30.0"));

    await uniV3Router.connect(b50).exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: usdc.address,
          fee: 500,
          recipient: b50Address,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("30.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    );

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq('10192097560');

    await optionScalp.connect(user1).closePosition(3);

    quoteBalance = await usdc.balanceOf(user1.address);

    expect(quoteBalance).to.eq('10255284526');

    const profit = quoteBalance.sub(startQuoteBalance);

    expect(profit).to.eq("-17088034"); // $17.08
  });

  it("user 1 opens a short scalp position, eth pumps, position is liquidated", async function() {
  });

  it("user 1 opens a long scalp position, eth drops, position is liquidated", async function() {
  });

  it("user 0 withdraws portion of eth deposit with pnl", async function() {
  });

  it("user 0 withdraws portion of usd deposit with pnl", async function() {
  });

  it("user 1 opens a long scalp position and user 0 cannot withdraw more than available liquidity", async function() {
  });

  it("user 1 closes long scalp position and user 0 withdraws remaining available liquidity", async function() {
  });
});