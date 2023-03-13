const { ethers } = require("hardhat");

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deployer } = await getNamedAccounts();

  const usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
  // WETH
  const weth = await ethers.getContractAt("contracts/interface/IWETH9.sol:IWETH9", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");

  const optionScalp = await deployments.deploy("OptionScalp", {
    args: [
      weth.address,
      usdc.address,
      "0x2b99e3D67dAD973c1B9747Da742B7E26c8Bdd67B",
      "0x7745370DFcC3780DD7675995b529d4e24960c015",
      "0x19e6eE4C2cBe7Bcc4cd1ef0BCF7e764fECe23cC6",
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3 ROUTER
      "0xa028B56261Bb1A692C06D993c383c872B51AfB33", // GMX HELPER
      "10000000", // $10
      "0x9c21ca464a2ee450d05d605d74ad415c6baaa054" // Insurance fund
    ],
    from: deployer,
    log: true,
  });

  console.log(optionScalp.address);
};
