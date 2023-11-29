const { ethers } = require("hardhat");

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deployer } = await getNamedAccounts();
  let limitOrders;

  // USDC
  const usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
  // WETH
  const weth = await ethers.getContractAt("contracts/interface/IWETH9.sol:IWETH9", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
  // ARB
  const arb = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0x912CE59144191C1204E64559FE8253a0e49E6548");

  const LimitOrders = await ethers.getContractFactory("LimitOrderManager");
  limitOrders = await LimitOrders.deploy([]);

  const insuranceFund = "0x55594cce8cc0014ea08c49fd820d731308f204c1";

  const wethOptionScalp = await deployments.deploy("OptionScalp", {
    args: [
      weth.address,
      usdc.address,
      18,
      6,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      limitOrders.address,
      "0xC36442b4a4522E871399CD717aBDD847Ab11FE88", // UNI V3 NFT Manager
      [
          "100000000000",  // $100.000
          "10000000000000",  // $10M
          "0x35cfa5ac5edb29769f92e16b6b68efa60b810a8e", // option pricing
          "0xa03f6f7c2b7fe70fcaf05c98f4fb083087ba58fd", // volatility oracle
          "0x19e6ee4c2cbe7bcc4cd1ef0bcf7e764fece23cc6", // price oracle
          insuranceFund, // Insurance fund
          "10000000", // $10
          "5000000", // 0.05%
          "3000",
          "3600"
      ]
    ],
    from: deployer,
    log: true,
  });

  console.log(wethOptionScalp.address);

  const arbOptionScalp = await deployments.deploy("OptionScalp", {
    args: [
      arb.address,
      usdc.address,
      18,
      6,
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      limitOrders.address,
      "0xC36442b4a4522E871399CD717aBDD847Ab11FE88", // UNI V3 NFT Manager
      [
          "10000000000",  // $10.000
          "10000000000000",  // $10M
          "0x35cfa5ac5edb29769f92e16b6b68efa60b810a8e", // option pricing
          "0xa03f6f7c2b7fe70fcaf05c98f4fb083087ba58fd", // volatility oracle
          "0xbdb0f3330d4b32b3133738451c8237d0a8af3081", // price oracle
          insuranceFund, // Insurance fund
          "10000000", // $10
          "5000000", // 0.05%
          "4000",
          "3600"
      ]
    ],
    from: deployer,
    log: true,
  });

  console.log(arbOptionScalp.address);

  await limitOrders.addOptionScalps([wethOptionScalp.address, arbOptionScalp.address]);
};
