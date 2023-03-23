const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Option scalp", function() {
  let signers;
  let owner;

  let usdc;
  let weth;
  let wbtc;
  let wbtcethPriceOracle;
  let quoteLp;
  let baseLp;
  let uniV3Router;
  let ethUsdPriceOracle;
  let volatilityOracle;
  let optionPricing;
  let optionScalp;
  let b50;
  let bf5;
  let b50Address;
  let bf5Address;
  let b7b;
  let b7bAddress;


  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
    user3 = signers[4];

    // WBTC
    wbtc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f");
    // USDC
    usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
    // WETH
    weth = await ethers.getContractAt("contracts/interface/IWETH9.sol:IWETH9", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    // Uni v3 router
    uniV3Router = await ethers.getContractAt("contracts/interface/IUniswapV3Router.sol:IUniswapV3Router", "0xE592427A0AEce92De3Edee1F18E0157C05861564");
  });

  it("should deploy option scalp ETHUSD with oracles", async function() {
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
    // Price oracle
    ethUsdPriceOracle = await ethers.getContractAt("contracts/mock/MockPriceOracle.sol:MockPriceOracle", "0x19e6eE4C2cBe7Bcc4cd1ef0BCF7e764fECe23cC6");
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
      18,
      6,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      [
          "100000000000",  // $100.000
          "10000000000000",  // $10M
          optionPricing.address,
          volatilityOracle.address,
          ethUsdPriceOracle.address,
          "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13", // Insurance fund
          "10000000", // $10
          "5000000", // 0.05%
          "5000000",  // $5
          "60" // 1 minutes
      ]
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

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0x7B7B957c284C2C227C980d6E2F804311947b84d0"],
    });

    b50Address = "0xE2F35B376461E7FDd2f2E45248E4c3cD9626A933";
    bf5Address = "0x9fc3b6191927b044ef709addd163b15c933ee205";
    b7bAddress = "0x7B7B957c284C2C227C980d6E2F804311947b84d0";

    b50 = await ethers.provider.getSigner(
      b50Address
    );

    bf5 = await ethers.provider.getSigner(
      bf5Address
    );

    b7b = await ethers.provider.getSigner(
      b7bAddress
    );

    await weth.connect(b50).transfer(user0.address, ethers.utils.parseEther("15.0"));
    await usdc.connect(bf5).transfer(user0.address, "10000000000");
    await wbtc.connect(b7b).transfer(user0.address, "5000000000");

    await weth.connect(b50).transfer(user1.address, ethers.utils.parseEther("15.0"));
    await usdc.connect(bf5).transfer(user1.address, "10000000000");
    await wbtc.connect(b7b).transfer(user1.address, "5000000000");

    await b50.sendTransaction({
        to: user0.address,
        value: ethers.utils.parseEther("5.0")
    });
  });

  it("user 0 deposits", async function() {
    await usdc.connect(user0).approve(optionScalp.address, "10000000000");
    await weth.connect(user0).approve(optionScalp.address, ethers.utils.parseEther("10.0"));

    await expect(optionScalp.connect(user0).deposit(user0.address, true, "100000000000000000000000")).to.be.revertedWith("ERC20: transfer amount exceeds balance");

    await optionScalp.connect(user0).deposit(user0.address, true, "10000000000");

    await optionScalp.connect(user0).deposit(user0.address, false, ethers.utils.parseEther("10.0"));
  });

  it("user 0 withdraws half", async function() {
    const scalpLpAddress = await optionScalp.connect(user0).quoteLp();
    quoteLp = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", scalpLpAddress);
    const balance = await quoteLp.balanceOf(user0.address);
    expect(balance).to.eq("10000000000");

    expect(user0.address).to.eq("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");

    // Allowance is required
    await quoteLp.connect(user0).approve(optionScalp.address, "1000000000000000000000000000000000");

    await expect(optionScalp.connect(user0).withdraw(true, balance.div(2))).to.be.revertedWith('Cooling period');

    await network.provider.send("evm_increaseTime", [60]);
    await network.provider.send("evm_mine");

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
    await optionScalp.connect(user1).openPosition(true, "5000000000", 0, "20000000", "0"); // 5000$ long

    let quoteBalance = await usdc.balanceOf(user1.address);
    expect(quoteBalance).to.eq('9976732757');

    const amountPaid = startQuoteBalance.sub(quoteBalance);
    expect(amountPaid).to.eq("23267243"); // 20$ of margin + 1.27$ of premium + 2.5$ of fees
  });

  it("should deploy option scalp WBTCUSD with oracles", async function() {
    // Uni v3 router
    uniV3Router = await ethers.getContractAt("contracts/interface/IUniswapV3Router.sol:IUniswapV3Router", "0xE592427A0AEce92De3Edee1F18E0157C05861564");
    // Price oracle
    wbtcethPriceOracle = await (await ethers.getContractFactory("EthBtcPriceOracle")).deploy();
    // Volatility oracle
    const VolatilityOracle = await ethers.getContractFactory("VolatilityOracleSimple");
    volatilityOracle = await VolatilityOracle.deploy();
    // Option pricing
    const OptionPricing = await ethers.getContractFactory("OptionPricingSimple");
    optionPricing = await OptionPricing.deploy(1000, 1);

    // Option scalp
    const OptionScalp = await ethers.getContractFactory("OptionScalp");
    optionScalp = await OptionScalp.deploy(
      wbtc.address,
      weth.address,
      8,
      18,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      [
          "10000000000000000000",  // 10 ETH
          "1000000000000000000000",  // 1000 ETH
          optionPricing.address,
          volatilityOracle.address,
          wbtcethPriceOracle.address,
          "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13", // Insurance fund
          "5000000000000000", // 0.005
          "5000000", // 0.05%
          "2500000000000000",  // 0.0025
          "60" // 1 minute
      ]
    );

    // Base LP
    baseLp = (await ethers.getContractFactory("ScalpLP")).attach((await optionScalp.baseLp()));

    // Quote LP
    quoteLp = (await ethers.getContractFactory("ScalpLP")).attach((await optionScalp.quoteLp()));

    console.log("deployed option scalp:", optionScalp.address);

    // Mark price
    const markPrice = await optionScalp.getMarkPrice();
    expect(markPrice).to.eq("14411456162746889162"); // 1 BTC : 14.411 ETH
  });

  it("user 0 deposits", async function() {
    await wbtc.connect(user0).approve(optionScalp.address, "10000000000");
    await weth.connect(user0).approve(optionScalp.address, ethers.utils.parseEther("10.0"));

    await expect(optionScalp.connect(user0).deposit(user0.address, true, "100000000000000000000000")).to.be.revertedWith("ERC20: transfer amount exceeds balance");

    expect((await weth.balanceOf(user0.address))).to.eq("5000000000000000000");
    expect((await wbtc.balanceOf(user0.address))).to.eq("5000000000");

    await optionScalp.connect(user0).deposit(user0.address, true, ethers.utils.parseEther("4.0")); // 4 ETH
    await optionScalp.connect(user0).deposit(user0.address, false, "400000000"); // 4 BTC
  });

  it("user 0 withdraws half", async function() {
    const scalpLpAddress = await optionScalp.connect(user0).quoteLp();
    quoteLp = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", scalpLpAddress);
    const balance = await quoteLp.balanceOf(user0.address);
    expect(balance).to.eq("4000000000000000000");

    // Allowance is required
    await quoteLp.connect(user0).approve(optionScalp.address, "1000000000000000000000000000000000");

    await network.provider.send("evm_increaseTime", [60]);
    await network.provider.send("evm_mine");

    await expect(optionScalp.connect(user0).withdraw(true, "5000000000000000000")).to.be.revertedWith('Not enough available assets to satisfy withdrawal');

    const startQuoteBalance = await weth.balanceOf(user0.address);
    await optionScalp.connect(user0).withdraw(true, balance.div(2));
    const endQuoteBalance = await weth.balanceOf(user0.address);

    const quoteOut = endQuoteBalance.sub(startQuoteBalance);
    expect(quoteOut).to.eq("2000000000000000000"); // 2 ETH
  });

  it("user 1 opens a short scalp position, btc goes up, position is closed", async function() {
    const startQuoteBalance = await weth.balanceOf(user1.address);
    expect(startQuoteBalance).to.eq('15000000000000000000');

    await weth.connect(user1).approve(optionScalp.address, "1000000000000000000");
    await optionScalp.connect(user1).openPosition(true, "1000000000000000000", 0, "100000000000000000", "0"); // 1 ETH long on BTC/ETH, 0.1 ETH of margin

    let quoteBalance = await weth.balanceOf(user1.address);
    expect(quoteBalance).to.eq('14899346551269203120');

    const amountPaid = startQuoteBalance.sub(quoteBalance);
    expect(amountPaid).to.eq("100653448730796880"); // 0.1 ETH of margin + 0.000755747882 ETH of fees and premium

    await weth.connect(b7b).deposit({value: ethers.utils.parseEther("260.0")});
    await weth.connect(b7b).approve(uniV3Router.address, ethers.utils.parseEther("1000.0"));

    let actualPrice = (await uniV3Router.connect(b7b).callStatic.exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: wbtc.address,
          fee: 500,
          recipient: b7bAddress,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("1.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    ));

    expect(actualPrice).to.eq("6936534"); // 0.06936534 BTC for 1 ETH

    await uniV3Router.connect(b7b).exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: wbtc.address,
          fee: 500,
          recipient: b7bAddress,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("140.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    );

    quoteBalance = await weth.balanceOf(user1.address);

    expect(quoteBalance).to.eq('14899346551269203120');

    actualPrice = (await uniV3Router.connect(b7b).callStatic.exactInputSingle(
        {
          tokenIn: weth.address,
          tokenOut: wbtc.address,
          fee: 500,
          recipient: b7bAddress,
          deadline: "999999999999999999999999",
          amountIn: ethers.utils.parseEther("1.0"),
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0
        }
    )).mul(BigNumber.from("100"));

    expect(actualPrice).to.eq("689603200"); // 0.06896032 BTC for 1 ETH

    // price pumps from 1/0.06936534 to 1/0.06896032
    // size was 1 ETH so positions is 1 / (1/0.06936534) = 0.06936534, expected profit is 0.06936534 * -0.0846709986 = -0.00587323261 ETH

    expect((await optionScalp.isLiquidatable(1))).to.eq(false);

    await optionScalp.connect(user1).closePosition(1);

    quoteBalance = await weth.balanceOf(user1.address);

    expect(quoteBalance).to.eq('14992372883972932057');

    const profit = quoteBalance.sub(startQuoteBalance);

    expect(profit).to.eq("-7627116027067943"); // -0.100755748 ETH
  });

  it("user 0 withdraws all eth deposit with 0 pnl", async function() {
    const startQuoteBalance = await weth.balanceOf(user0.address);
    await quoteLp.connect(user0).approve(optionScalp.address, ethers.utils.parseEther("2.0"));

    await optionScalp.connect(user0).withdraw(true, ethers.utils.parseEther("2.0"));

    const endQuoteBalance = await weth.balanceOf(user0.address);

    const difference = endQuoteBalance.sub(startQuoteBalance);

    expect(difference).to.eq("2000000000000000000"); // 2 ETH
  });

  it("user 0 withdraws all wbtc deposit with positive pnl", async function() {
    const startBaseBalance = await wbtc.balanceOf(user0.address);

    const baseLpAmount = (await baseLp.balanceOf(user0.address));
    expect(baseLpAmount).to.eq("400000000");

    await baseLp.connect(user0).approve(optionScalp.address, baseLpAmount);
    await optionScalp.connect(user0).withdraw(false, baseLpAmount);

    const endBaseBalance = await wbtc.balanceOf(user0.address);

    const difference = endBaseBalance.sub(startBaseBalance);

    expect(difference).to.eq("400001063");
  });
});