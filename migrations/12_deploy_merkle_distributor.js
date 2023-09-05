const MerkleDistributor = artifacts.require("MerkleDistributor");

const {
  TOKEN,
  ERC20_USER
} = process.env;

module.exports = async function (deployer) {
  await deployer.deploy(
    MerkleDistributor,
    TOKEN,
    ERC20_USER,
    '0xac2780513795cff23cf9094165416604ea8669612674997c56f37aff62f64e04',
  );
};
