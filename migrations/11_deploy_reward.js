const Reward = artifacts.require("Reward");

const {
  TOKEN,
} = process.env;

module.exports = async function (deployer) {
  await deployer.deploy(
    Reward,
    TOKEN,
    [0, 1000, 5000, 10000, 20000],
    [10, 13, 15, 17, 21],
  );
};
