import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const deployAuctions: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  const multiverseDeployment = await hre.deployments.get("Multiverse");
  const multiverseAddress = multiverseDeployment.address;

  const auctionsResult = await deploy("Auctions", {
    from: deployer,
    args: [multiverseAddress],
    log: true,
    autoMine: true,
  });

  const auctionsAddress = auctionsResult.address;
  const multiverse = await hre.ethers.getContract("Multiverse", deployer);

  const currentAuctionsAddress = await multiverse.auctionsAddress();
  const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
  if (currentAuctionsAddress === ZERO_ADDRESS) {
    const tx = await multiverse.setAuctionsAddress(auctionsAddress, { gasLimit: 500_000 });
    await tx.wait();
    console.log(`✅ Multiverse.setAuctionsAddress(${auctionsAddress}) called`);
  } else {
    console.log(`ℹ️  Multiverse already has auctions address set: ${currentAuctionsAddress}`);
  }

  console.log(`🚀 Auctions deployed at: ${auctionsResult.address}`);
};

export default deployAuctions;
deployAuctions.tags = ["Auctions"];
deployAuctions.dependencies = ["Multiverse"];
