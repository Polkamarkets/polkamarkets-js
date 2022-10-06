const Voting = artifacts.require("Voting");

const {
  TOKEN,
  REQUIRED_BALANCE,
} = process.env;

module.exports = async function (deployer) {
  await deployer.deploy(
    Voting,
    TOKEN,
    REQUIRED_BALANCE
  );
};
