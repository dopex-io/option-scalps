const { ethers } = require("hardhat");

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deployer } = await getNamedAccounts();

  const usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
  // WETH
  const weth = await ethers.getContractAt("contracts/interface/IWETH9.sol:IWETH9", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
  // Uni v3 router
  const uniV3Router = await ethers.getContractAt("contracts/interface/IUniswapV3Router.sol:IUniswapV3Router", "0xE592427A0AEce92De3Edee1F18E0157C05861564");

  const optionPricing = await deployments.deploy("MockOptionPricing", {
    from: deployer,
    log: true,
  });

  const volatilityOracle = await deployments.deploy("MockVolatilityOracle", {
    from: deployer,
    log: true,
  });

  const priceOracle = await deployments.deploy("MockPriceOracle", {
    from: deployer,
    log: true,
  });

  const optionScalp = await deployments.deploy("OptionScalp", {
    args: [
      weth.address,
      usdc.address,
      optionPricing.address,
      volatilityOracle.address,
      priceOracle.address,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      "0xa028B56261Bb1A692C06D993c383c872B51AfB33", // GMX HELPER
      "10000000", // $10
      "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13" // Insurance fund
    ],
    from: deployer,
    log: true,
  });

  console.log(optionScalp.address);
};
