// const _ =  require("lodash");
// const moment = require("moment");

const reward = require("../interfaces").reward;

const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');

const actions = {
  0: 'Lock',
  1: 'Unlock',
}

/**
 * Reward Contract Object
 * @constructor RewardContract
 * @param {Web3} web3
 * @param {Integer} decimals
 * @param {Address} contractAddress
 */

class RewardContract extends IContract {
  constructor(params) {
    super({ abi: reward, ...params });
    this.contractName = 'reward';
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
   * @function getItemLockedAmount
   * @description Get Item Total amount locked
   * @param {Integer} itemId
   * @returns {Integer} total amount locked
   */
  async getItemLockedAmount({ itemId }) {
    const amountLocked = await this.params.contract
      .getContract()
      .methods
      .getItemLockedAmount(itemId)
      .call();

    const decimals = await this.getTokenDecimals();

    return Numbers.fromDecimalsNumber(amountLocked, decimals);
  }

  /**
   * @function getAmontUserLockedItem
   * @description Get the Total amount a user has locked for an item
   * @param {Address} user
   * @param {Integer} itemId
   * @returns {Integer} total amount locked
   */
  async getAmontUserLockedItem({ user, itemId }) {
    const amountLocked = await this.params.contract
      .getContract()
      .methods
      .amountUserLockedItem(user, itemId)
      .call();

    const decimals = await this.getTokenDecimals();

    return Numbers.fromDecimalsNumber(amountLocked, decimals);
  }

  /**
   * @function getNumberOfTiers
   * @description Get the number of tiers configured
   * @returns {Integer} number of tiers
   */
  async getNumberOfTiers() {
    const numberOfTiers = await this.params.contract
      .getContract()
      .methods
      .getNumberOfTiers()
      .call();

    return parseInt(numberOfTiers);
  }

  /**
   * @function getUserActions
   * @description Get user locking actions
   * @param {Address} user
   * @returns {Array} Actions
   */
  async getUserActions({ user }) {
    const decimals = await this.getTokenDecimals();
    const events = await this.getEvents('ItemAction', { user });

    return events.map(event => {
      return {
        action: actions[Numbers.fromBigNumberToInteger(event.returnValues.action, decimals)],
        itemId: Numbers.fromBigNumberToInteger(event.returnValues.itemId, decimals),
        lockAmount: Numbers.fromDecimalsNumber(event.returnValues.lockAmount, decimals),
        timestamp: Numbers.fromBigNumberToInteger(event.returnValues.timestamp, decimals),
        transactionHash: event.transactionHash,
      }
    });
  }

  /* POST User Functions */

  /**
   * @function lockItem
   * @description Lock an amount on an item
   * @param {Integer} itemId
   * @param {Integer} amount
   */
  async lockItem({ itemId, amount }) {
    const decimals = await this.getTokenDecimals();
    const amountDecimals = Numbers.toSmartContractDecimals(amount, decimals);

    return await this.__sendTx(
      this.getContract().methods.lockItem(itemId, amountDecimals)
    );
  };

  /**
   * @function unlockItem
   * @description Unlock the amount of an item
   * @param {Integer} itemId
   */
  async unlockItem({ itemId, amount }) {
    const decimals = await this.getTokenDecimals();
    const amountDecimals = Numbers.toSmartContractDecimals(amount, decimals);

    return await this.__sendTx(
      this.getContract().methods.unlockItem(itemId, amountDecimals)
    );
  };


  /**
   * @function unlockMultipleItems
   * @description Unlock the amount of multiple items at the same time
   * @param {Integer} itemId
   */
  async unlockMultipleItems({ itemIds, amounts }) {
    const decimals = await this.getTokenDecimals();
    const amountsDecimals = amounts.map(amount => Numbers.toSmartContractDecimals(amount, decimals));

    return await this.__sendTx(
      this.getContract().methods.unlockMultipleItems(itemIds, amountsDecimals)
    );
  };

}

module.exports = RewardContract;
