const Reward = artifacts.require("Reward");

const {
  TOKEN,
} = process.env;

module.exports = async function (deployer) {
  await deployer.deploy(
    Reward,
    TOKEN,
    [
      {
        minAmount: 0,
        multiplier: 1,
      },
      {
        minAmount: 1000,
        multiplier: 1.3,
      },
      {
        minAmount: 5000,
        multiplier: 1.5,
      },
      {
        minAmount: 10000,
        multiplier: 1.7,
      },
      {
        minAmount: 20000,
        multiplier: 2.1,
      },
    ]
  );
};
