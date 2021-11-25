const Contract = require("../utils/Contract");
const _ = require("lodash");
const axios = require('axios');

/**
 * Contract Object Interface
 * @constructor IContract
 * @param {Web3} web3
 * @param {Address} contractAddress ? (opt)
 * @param {ABI} abi
 * @param {Account} acc ? (opt)
 */

class IContract {
  constructor({
    web3,
    contractAddress = null /* If not deployed */,
    abi,
    acc,
    web3EventsProvider
  }) {
    try {
      if(!abi){
        throw new Error("No ABI Interface provided");
      }
      if(!web3){
        throw new Error("Please provide a valid web3 provider");
      };

      this.web3 = web3;

      if (acc) {
        this.acc = acc;
      }

      this.params = {
        web3,
        abi,
        contractAddress,
        web3EventsProvider,
        contract: new Contract(web3, abi, contractAddress)
      };
    } catch (err) {
      throw err;
    }
  }

  async __init__() {
    try {
      if (!this.getAddress()) {
        throw new Error("Please add a Contract Address");
      }

      await this.__assert();
    } catch (err) {
      throw err;
    }
  };

  async __metamaskCall ({ f, acc, value, callback=()=> {} }) {
    return f.send({
      from: acc,
      value: value,
    })
    .on("confirmation", (confirmationNumber, receipt) => {
      callback(confirmationNumber)
      if (confirmationNumber > 0) {
        resolve(receipt);
      }
    })
    .on("error", (err) => {
      reject(err);
    });
  };

  async __sendTx(f, call = false, value, callback=()=>{}) {
    try{
      var res;
      if (!this.acc && !call) {
        const accounts = await this.params.web3.eth.getAccounts();
        res = await this.__metamaskCall({ f, acc: accounts[0], value, callback });
      } else if (this.acc && !call) {
        let data = f.encodeABI();
        res = await this.params.contract.send(
          this.acc.getAccount(),
          data,
          value
        ).catch(err => {throw err;});
      } else if (this.acc && call) {
        res = await f.call({ from : this.acc.getAddress() }).catch(err => {throw err;});
      } else {
        res = await f.call().catch(err => {throw err;});
      }
      return res;
    }catch(err){
      throw err;
    }
  };

  async __deploy(params, callback) {
    return await this.params.contract.deploy(
      this.acc,
      this.params.contract.getABI(),
      this.params.contract.getJSON().bytecode,
      params,
      callback
    );
  };

  async __assert() {
    if(!this.getAddress()){
      throw new Error("Contract is not deployed, first deploy it and provide a contract address");
    }
    /* Use ABI */
    this.params.contract.use(this.params.abi, this.getAddress());
  }

  /**
   * @function deploy
   * @description Deploy the Contract
  */
  async deploy({callback, params = []}) {
    let res = await this.__deploy(params, callback);
    this.params.contractAddress = res.contractAddress;
    /* Call to Backend API */
    await this.__assert();
    return res;
  };


  /**
   * @function setNewOwner
   * @description Set New Owner of the Contract
   * @param {string} address
   */
  async setNewOwner({ address }){
    return await this.__sendTx(
      this.params.contract
        .getContract()
        .methods.transferOwnership(address)
    );
  }

  /**
   * @function owner
   * @description Get Owner of the Contract
   * @returns {string} address
   */

  async owner() {
    return await this.params.contract.getContract().methods.owner().call();
  }

  /**
   * @function isPaused
   * @description Get Owner of the Contract
   * @returns {boolean}
   */

  async isPaused() {
    return await this.params.contract.getContract().methods.paused().call();
  }

  /**
   * @function pauseContract
   * @type admin
   * @description Pause Contract
   */
  async pauseContract() {
    return await this.__sendTx(
      this.params.contract.getContract().methods.pause()
    );
  }

  /**
   * @function unpauseContract
   * @type admin
   * @description Unpause Contract
   */
  async unpauseContract() {
    return await this.__sendTx(
      this.params.contract.getContract().methods.unpause()
    );
  }

  /* Optional */

  /**
   * @function removeOtherERC20Tokens
   * @description Remove Tokens from other ERC20 Address (in case of accident)
   * @param {Address} tokenAddress
   * @param {Address} toAddress
   */
  async removeOtherERC20Tokens({ tokenAddress, toAddress }){
    return await this.__sendTx(
      this.params.contract
        .getContract()
        .methods.removeOtherERC20Tokens(tokenAddress, toAddress)
    );
  };

  /**
   * @function safeGuardAllTokens
   * @description Remove all tokens for the sake of bug or problem in the smart contract, contract has to be paused first, only Admin
   * @param {Address} toAddress
   */
  async safeGuardAllTokens({ toAddress }){
    return await this.__sendTx(
      this.params.contract
        .getContract()
        .methods.safeGuardAllTokens(toAddress)
    );
  };

  /**
   * @function changeTokenAddress
   * @description Change Token Address of Application
   * @param {Address} newTokenAddress
   */
  async changeTokenAddress({ newTokenAddress }){
    return await this.__sendTx(
      this.params.contract
        .getContract()
        .methods.changeTokenAddress(newTokenAddress)
    );
  };

  /**
   * @function getAddress
   * @description Get Balance of Contract
   * @param {Integer} Balance
   */
  getAddress(){
    return this.params.contractAddress;
  }

  /**
   * @function getContract
   * @description Gets Contract
   * @return {Contract} Contract
   */
  getContract() {
    return this.params.contract.getContract();
  }

  /**
   * @function getBalance
   * @description Get Balance of Contract
   * @param {Integer} Balance
   */

  async getBalance(){
    let wei = await this.web3.eth.getBalance(this.getAddress());
    return this.web3.utils.fromWei(wei, 'ether');
  };

  /**
   * @function getMyAccount
   * @description Returns connected wallet account address
   * @returns {String | undefined} address
   */
  async getMyAccount() {
    if (this.acc) {
      return this.acc.getAddress()
    }

    const accounts = await this.params.web3.eth.getAccounts();

    return accounts[0];
  }

  /**
   * @function getEvents
   * @description Gets contract events
   * @returns {String | undefined} address
   */
  async getEvents(event, filter) {
    if (!this.params.web3EventsProvider) {
      const events = this.getContract().getPastEvents(event, {
        fromBlock: 0,
        toBlock: 'latest',
        filter
      });

      return events;
    }

    // getting events via http from web3 events provide
    let uri = `${this.params.web3EventsProvider}/events?contract=${this.contractName}&address=${this.getAddress()}&eventName=${event}`
    if (filter) uri = uri.concat(`&filter=${JSON.stringify(filter)}`);

    const { data } = await axios.get(uri);
    return data;
  }
}

module.exports = IContract;
