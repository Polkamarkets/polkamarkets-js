// const _ =  require("lodash");
// const moment = require("moment");

const voting = require("../interfaces").voting;

const Numbers = require("../utils/Numbers");
const IContract = require('./IContract');

const actions = {
  0: 'Upvoted',
  1: 'Remove Upvoted',
  2: 'Downvoted',
  3: 'Remove Downvoted',
}

/**
 * Voting Contract Object
 * @constructor VotingContract
 * @param {Web3} web3
 * @param {Integer} decimals
 * @param {Address} contractAddress
 */

class VotingContract extends IContract {
  constructor(params) {
    super({ ...params, abi: voting });
    this.contractName = 'voting';
  }

  /* Get Functions */
  /**
   * @function getMinimumRequiredBalance
   * @description Returns minimum required ERC20 balance to vote
   * @returns {Integer} requiredBalance
   */
  async getMinimumRequiredBalance() {
    const requiredBalance = await this.params.contract
      .getContract()
      .methods
      .requiredBalance()
      .call();

    return Numbers.fromDecimalsNumber(requiredBalance, 18)
  }

  /**
   * @function getItemVotes
   * @description Get Item Total upvotes and downvotes
   * @param {Integer} itemId
   * @returns {Integer} upvotes
   * @returns {Integer} downvotes
   */
  async getItemVotes({ itemId }) {
    let res = await this.params.contract
      .getContract()
      .methods
      .getItemVotes(itemId)
      .call();

    return {
      upvotes: Number(res[0]),
      downvotes: Number(res[1]),
    }
  }

  /**
   * @function haveIVotedItem
   * @description Get info if I have voted the item
   * @param {Integer} itemId
   * @returns {Boolean} upvoted
   * @returns {Boolean} downvoted
   */
  async haveIVotedItem({ itemId }) {
    const account = await this.getMyAccount();
    if (!account) return { upvoted: 0, downvoted: 0 };

    return this.hasUserVotedItem({ user: account, itemId });
  }

  /**
   * @function hasUserVotedItem
   * @description Get info if user has voted the item
   * @param {Integer} itemId
   * @param {Address} user
   * @returns {Boolean} upvoted
   * @returns {Boolean} downvoted
   */
  async hasUserVotedItem({ user, itemId }) {
    let res = await this.params.contract
      .getContract()
      .methods
      .hasUserVotedItem(user, itemId)
      .call();

    return {
      upvoted: res[0],
      downvoted: res[1],
    }
  }

  /**
   * @function getMyActions
   * @description Get my voting actions
   * @returns {Array} Voted Actions
   */
  async getMyActions() {
    const account = await this.getMyAccount();
    if (!account) return [];

    return this.getActions({ user: account });
  }

  /**
   * @function getMyActions
   * @description Get user voting actions
   * @param {Address} user
   * @returns {Array} Voted Actions
   */
  async getActions({ user }) {
    const events = await this.getEvents('ItemVotesAction', { user });

    return events.map(event => {
      return {
        action: actions[Numbers.fromBigNumberToInteger(event.returnValues.action, 18)],
        itemId: Numbers.fromBigNumberToInteger(event.returnValues.itemId, 18),
        timestamp: Numbers.fromBigNumberToInteger(event.returnValues.timestamp, 18),
        transactionHash: event.transactionHash,
      }
    });
  }


  /* POST User Functions */

  /**
   * @function upvoteItem
   * @description Upvote an item
   * @param {Integer} itemId
   */
  async upvoteItem({ itemId }) {
    return await this.__sendTx(
      this.getContract().methods.upvoteItem(itemId)
    );
  };

  /**
   * @function downvoteItem
   * @description Downvote an item
   * @param {Integer} itemId
   */
  async downvoteItem({ itemId }) {
    return await this.__sendTx(
      this.getContract().methods.downvoteItem(itemId)
    );
  };


  /**
   * @function removeUpvoteItem
   * @description Remove Upvote from an item
   * @param {Integer} itemId
   */
  async removeUpvoteItem({ itemId }) {
    return await this.__sendTx(
      this.getContract().methods.removeUpvoteItem(itemId)
    );
  };

  /**
   * @function removeDownvoteItem
   * @description Remove Downvote from an item
   * @param {Integer} itemId
   */
  async removeDownvoteItem({ itemId }) {
    return await this.__sendTx(
      this.getContract().methods.removeDownvoteItem(itemId)
    );
  };
}

module.exports = VotingContract;
