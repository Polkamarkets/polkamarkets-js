const Contract = require("../utils/Contract");
const _ = require("lodash");
const axios = require('axios');
const AccountAbstraction = require("../utils/AccountAbstraction");
const ethers = require('ethers').ethers;

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
    web3EventsProvider,
    gasPrice,
    isSocialLogin = false,
    socialLoginType = 'SFAParticle'
  }) {
    try {
      if (!abi) {
        throw new Error("No ABI Interface provided");
      }
      if (!web3) {
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
        gasPrice,
        contract: new Contract(web3, abi, contractAddress),
        isSocialLogin,
        socialLoginType
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

  async __metamaskCall({ f, acc, value, callback = () => { } }) {
    return f.send({
      from: acc,
      value: value,
      gasPrice: this.params.gasPrice,
      maxPriorityFeePerGas: null,
      maxFeePerGas: null
    })
      .on("confirmation", (confirmationNumber, receipt) => {
        callback(confirmationNumber)
        if (confirmationNumber > 0) {
          resolve(receipt);
        }
      })
      .on("error", (err) => {
        throw err;
        // reject(err);
      });
  };

  waitForTransactionHashToBeGenerated(userOpHash, networkConfig) {
    return new Promise((resolve, reject) => {
      const interval = setInterval(async () => {
        const userOperation = await axios.post(`${networkConfig.bundlerRPC}/rpc?chainId=${networkConfig.chainId}`,
          {
            "method": "eth_getUserOperationByHash",
            "params": [
              userOpHash
            ]
          }
        );

        if (userOperation.data.result && userOperation.data.result.transactionHash) {
          clearInterval(interval);
          resolve(userOperation.data.result.transactionHash);
        } else if (networkConfig.bundlerAPI) {
          let userOperationData;
          try {
            userOperationData = await axios.get(`${networkConfig.bundlerAPI}/user_operations/${userOpHash}`);
          } catch (error) {
            // fetch should be non-blocking
          }

          if (userOperationData?.data?.status === 'failed') {
            clearInterval(interval);
            reject(new Error('User operation failed'));
          }
        }
      }, 1000);
    });
  }

  operationDataFromCall(f) {
    return {
      contract: this.params.abi.contractName,
      method: f._method.name,
      arguments: f.arguments,
    };
  }

  async sendGaslessTransactions(f) {
    const PolkamarketsSocialLogin = AccountAbstraction.getSocialLogin(this.params.socialLoginType);
    const socialLogin = PolkamarketsSocialLogin.singleton.getInstance();
    const smartAccount = socialLogin.smartAccount;

    const networkConfig = smartAccount.networkConfig;

    const { isMetamask, signer } = await socialLogin.providerIsMetamask();

    const methodName = f._method.name;

    const contractInterface = new ethers.utils.Interface(this.params.abi.abi);
    const methodCallData = contractInterface.encodeFunctionData(methodName, f.arguments);

    const tx = {
      to: this.params.contractAddress,
      data: methodCallData,
    };

    try {
      let receipt;

      if (isMetamask) {
        const txResponse = await signer.sendTransaction({ ...tx, gasLimit: 210000 });
        receipt = await txResponse.wait();
      } else {
        if (this.params.socialLoginType === 'PnPBiconomy') {
          const txResponse = await smartAccount.sendTransaction({
            transaction: tx
          });

          receipt = await txResponse.wait();

        } else {
          // trying operation 3 times
          const retries = 3;
          let feeQuotesResult;
          for (let i = 0; i < retries; i++) {
            try {
              feeQuotesResult = await smartAccount.getFeeQuotes(tx);
              break;
            } catch (error) {
              await new Promise((resolve) => setTimeout(resolve, 5000));

              if (i === retries - 1) {
                throw error;
              } else {
                // 1s interval between retries
                await new Promise((resolve) => setTimeout(resolve, 1000));
              }
            }
          }

          const userOp = feeQuotesResult.verifyingPaymasterGasless?.userOp;
          const userOpHash = feeQuotesResult.verifyingPaymasterGasless?.userOpHash;

          // TODO: remove console.log
          console.log(userOp);
          console.log(userOpHash);

          const signedUserOp = await smartAccount.signUserOperation({ userOpHash, userOp });

          let txResponse;
          for (let i = 0; i < retries; i++) {
            try {
              if (networkConfig.bundlerAPI) {
                txResponse = await axios.post(`${networkConfig.bundlerAPI}/user_operations`,
                  {
                    user_operation: {
                      user_operation: signedUserOp,
                      user_operation_hash: userOpHash,
                      user_operation_data: [this.operationDataFromCall(f)],
                      user_method_call_data: methodCallData,
                      network_id: networkConfig.chainId,
                    }
                  }
                );
              } else {
                txResponse = await axios.post(`${networkConfig.bundlerRPC}/rpc?chainId=${networkConfig.chainId}`,
                  {

                    "method": "eth_sendUserOperation",
                    "params": [
                      signedUserOp,
                      "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789"
                    ]
                  }
                );
              }

              if (!txResponse.data.error) break;
            } catch (error) {
              if (i === retries - 1) {
                throw error;
              } else {
                // 1s interval between retries
                await new Promise((resolve) => setTimeout(resolve, 1000));
              }
            }
          }

          if (txResponse.data.error) {
            throw new Error(txResponse.data.error.message);
          }

          const transactionHash = await this.waitForTransactionHashToBeGenerated(userOpHash, networkConfig);

          const web3Provider = new ethers.providers.Web3Provider(socialLogin?.provider)

          receipt = await web3Provider.waitForTransaction(transactionHash);
        }
      }

      if (receipt.logs) {
        const events = receipt.logs.map(log => {
          try {
            const event = contractInterface.parseLog(log);
            return event;
          } catch (error) {
            return null;
          }
        });
        receipt.events = this.convertEtherEventsToWeb3Events(events);
      }

      return receipt;
    } catch (error) {
      console.error(error);
      throw error;
    }
  }

  convertEtherEventsToWeb3Events(events) {
    const transformedEvents = {};
    for (const event of events) {
      if (!event) {
        continue;
      }

      const { name, args, eventFragment } = event;

      const returnValues = {};

      eventFragment.inputs.forEach((input, index) => {
        let value = args[index];

        // if value is a BigNumber, convert it to a string
        if (ethers.BigNumber.isBigNumber(value)) {
          value = value.toString();
        }

        returnValues[input.name] = value;
        returnValues[index.toString()] = value;
      });

      const transformedEvent = {
        event: name,
        returnValues,
      };

      transformedEvents[name] = transformedEvent;
    }

    return transformedEvents;
  }

  async __sendTx(f, call = false, value, callback = () => { }) {
    if (this.params.isSocialLogin && !call) {
      return await this.sendGaslessTransactions(f);
    } else {
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
        ).catch(err => { throw err; });
      } else if (this.acc && call) {
        res = await f.call({ from: this.acc.getAddress() }).catch(err => { throw err; });
      } else {
        res = await f.call().catch(err => { throw err; });
      }
      return res;
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
    if (!this.getAddress()) {
      throw new Error("Contract is not deployed, first deploy it and provide a contract address");
    }
    /* Use ABI */
    this.params.contract.use(this.params.abi, this.getAddress());
  }

  /**
   * @function deploy
   * @description Deploy the Contract
  */
  async deploy({ callback, params = [] }) {
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
  async setNewOwner({ address }) {
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
  async removeOtherERC20Tokens({ tokenAddress, toAddress }) {
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
  async safeGuardAllTokens({ toAddress }) {
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
  async changeTokenAddress({ newTokenAddress }) {
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
  getAddress() {
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

  async getBalance() {
    let wei = await this.web3.eth.getBalance(this.getAddress());
    return this.web3.utils.fromWei(wei, 'ether');
  };

  /**
   * @function getMyAccount
   * @description Returns connected wallet account address
   * @returns {String | undefined} address
   */
  async getMyAccount() {
    if (this.params.isSocialLogin) {
      const PolkamarketsSocialLogin = require("./PolkamarketsSocialLogin");
      const socialLogin = PolkamarketsSocialLogin.singleton.getInstance();
      return await socialLogin.getAddress();
    }

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
  async getEvents(event, filter, fromBlock = 0, toBlock = 'latest') {
    if (!this.params.web3EventsProvider) {
      const events = this.getContract().getPastEvents(event, {
        fromBlock,
        toBlock,
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

  /**
   * @function getBlock
   * @description Gets block details
   * @returns {Object} block
   */
  async getBlock(blockNumber) {
    return await this.params.web3.eth.getBlock(blockNumber);
  }
}

module.exports = IContract;
