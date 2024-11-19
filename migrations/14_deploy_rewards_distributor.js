const RewardsDistributor = artifacts.require("RewardsDistributor");

module.exports = async function(deployer) {
  await deployer.deploy(
    RewardsDistributor,
  );
}
