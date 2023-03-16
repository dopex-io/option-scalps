const { ethers } = require("hardhat");

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deployer } = await getNamedAccounts();

  // USDC
  const usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
  // WETH
  const weth = await ethers.getContractAt("contracts/interface/IWETH9.sol:IWETH9", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
  // WBTC
  const wbtc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0x2f2a2543b76a4166549f7aab2e75bef0aefc5b0f");

  const optionPricingSimple = await deployments.deploy("OptionPricingSimple", {
    args: [
      1000,
      1
    ],
    from: deployer,
    log: true,
  });

  const volatilityOracleSimple = await deployments.deploy("VolatilityOracleSimple", {
    args: [],
    from: deployer,
    log: true,
  });

  const wethOptionScalp = await deployments.deploy("OptionScalp", {
    args: [
      weth.address,
      usdc.address,
      18,
      6,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      "0xa028B56261Bb1A692C06D993c383c872B51AfB33", // GMX HELPER
      [
          "100000000000",  // $100.000
          "10000000000000",  // $10M
          optionPricingSimple.address,
          volatilityOracleSimple.address,
          "0x19e6eE4C2cBe7Bcc4cd1ef0BCF7e764fECe23cC6",
          "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13", // Insurance fund
          "10000000", // $10
          "5000000", // 0.05%
          "5000000",  // $5
      ]
    ],
    from: deployer,
    log: true,
  });

  console.log(wethOptionScalp.address);

  const wbtcethPriceOracle = await deployments.deploy("EthBtcPriceOracle", {
     args: [],
     from: deployer,
     logs: true,
  });

  const wbtcOptionScalp = await deployments.deploy("OptionScalp", {
    args: [
      wbtc.address,
      weth.address,
      8,
      18,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      "0xa028B56261Bb1A692C06D993c383c872B51AfB33", // GMX HELPER
      [
          "10000000000000000000",  // 10 ETH
          "1000000000000000000000",  // 1000 ETH
          optionPricingSimple.address,
          volatilityOracleSimple.address,
          wbtcethPriceOracle.address,
          "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13", // Insurance fund
          "5000000000000000", // 0.005
          "5000000", // 0.05%
          "2500000000000000",  // 0.0025
      ]
    ],
    from: deployer,
    log: true,
  });

  console.log(wbtcOptionScalp.address);
};
