import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const deployMultiverse: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  // If Multiverse needs the ERC20mb address, fetch it like this:
  // const token = await hre.deployments.get("ERC20mb");

  await deploy("Multiverse", {
    from: deployer,
    args: [
      // deployer,
      // token.address,   // <-- uncomment and add if your constructor needs it
      // other arguments...
    ],
    log: true,
    autoMine: true,
  });

  const multiverse = await hre.ethers.getContract("Multiverse", deployer);
  console.log(`🚀 Multiverse deployed at: ${await multiverse.getAddress()}`);
};

export default deployMultiverse;
deployMultiverse.tags = ["Multiverse"];

// Add dependency if Multiverse needs the token deployed first
deployMultiverse.dependencies = ["ERC20mb"];
