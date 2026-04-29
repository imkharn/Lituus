import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

/**
 * Deploys the ERC20mb token
 */
const deployERC20mb: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  // Change these values to whatever you want your token to be called
  const tokenName = "Multiverse Token";
  const tokenSymbol = "MVT";
  const initialSupply = hre.ethers.parseUnits("1000000", 18); // 1 million tokens (18 decimals)

  await deploy("ERC20mb", {
    from: deployer,
    args: [deployer, tokenName, tokenSymbol], // initialOwner, name, symbol
    log: true,
    autoMine: true, // speeds up local/hardhat network
  });

  // Get the freshly deployed token instance
  const token = await hre.ethers.getContract("ERC20mb", deployer);

  // Optional: mint an initial supply to the deployer (onlyOwner protected)
  // Remove or adjust if you don't want an initial mint
  const balanceBefore = await token.balanceOf(deployer);
  if (balanceBefore === 0n) {
    const mintTx = await token.mint(deployer, initialSupply, { gasLimit: 100_000 });
    await mintTx.wait();
    console.log(`✅ Minted ${hre.ethers.formatUnits(initialSupply, 18)} ${tokenSymbol} to deployer (${deployer})`);
  }

  console.log(`🚀 ERC20mb deployed at: ${await token.getAddress()}`);
  console.log(`   Name:   ${await token.name()}`);
  console.log(`   Symbol: ${await token.symbol()}`);
  console.log(`   Owner:  ${await token.owner()}`);
};

export default deployERC20mb;

// Tags let you deploy only this script if you want:
// yarn deploy --tags ERC20mb
deployERC20mb.tags = ["ERC20mb"];
