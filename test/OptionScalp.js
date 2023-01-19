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
});