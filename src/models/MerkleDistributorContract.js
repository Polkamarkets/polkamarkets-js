
const merkleDistributor = require('../interfaces').merkledistributor;

const Numbers = require('../utils/Numbers');
const IContract = require('./IContract');

/**
 * MerkleDistributor Contract Object
 * @constructor MerkleDistributorContract
 * @param {Web3} web3
 * @param {Address} contractAddress
 */

class MerkleDistributorContract extends IContract {
  constructor(params) {
    super({ abi: merkleDistributor, ...params });
    this.contractName = 'merkleDistributor';
  }

  /* Get Functions */

  /**
   * @function getTokenDecimals
   * @description Get Token Decimals
   * @return {Integer} decimals
   */
  async getTokenDecimals() {
    try {
      const contractAddress = await this.params.contract.getContract().methods.getTokenAddress().call();
      const erc20Contract = new ERC20Contract({ ...this.params, contractAddress });

      return await erc20Contract.getDecimalsAsync();
    } catch (err) {
      // defaulting to 18 decimals
      return 18;
    }
  }

  /**
   * @function isClaimed
   * @description Check if merkle tree index has claimed the tokens
   * @param {Integer} index
   * @return {Boolean} claimed
   */
  async isClaimed({ index }) {
    return await this.params.contract
      .getContract()
      .methods
      .isClaimed(index)
      .call();
  }


  /* POST User Functions */

  /**
   * @function claim
   * @description Claim the tokens
   * @param {Integer} index
   * @param {Address} account
   * @param {Integer} amount
   * @param {String[]} merkleProof
   */
  async claim({index, account, amount, merkleProof }) {
    const decimals = await this.getTokenDecimals();
    const amountDecimals = Numbers.toSmartContractDecimals(amount, decimals);

    return await this.__sendTx(
      this.getContract().methods.claim(index, account, `0x${Number(amountDecimals).toString(16)}`, merkleProof)
    );
  };

  /**
   * @function freeze
   * @description Freeze the contract to stop claims and be able to update merkle root
   */
  async freeze() {
    return await this.__sendTx(
      this.getContract().methods.freeze()
    );
  };

  /**
   * @function unfreeze
   * @description Unfreeze the contract to allow claims
   */
  async unfreeze() {
    return await this.__sendTx(
      this.getContract().methods.unfreeze()
    );
  };

  /**
   * @function updateMerkleRoot
   * @description Update Merkle Root
   * @param {String} merkleRoot
   */
  async updateMerkleRoot({merkleRoot}) {
    return await this.__sendTx(
      this.getContract().methods.updateMerkleRoot(merkleRoot)
    );
  };


}

module.exports = MerkleDistributorContract;
