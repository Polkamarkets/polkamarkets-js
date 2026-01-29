class Contract {
  constructor(web3, contract_json, address) {
    this.web3 = web3;
    this.json = contract_json;
    this.abi = contract_json.abi;
    this.address = address;
    this.contract = new web3.eth.Contract(contract_json.abi, address);
  }

  async deploy(account, abi, byteCode, args = [], callback = () => {}) {
    this.contract = new this.web3.eth.Contract(abi);
    if (account) {
      const data = this.contract.deploy({
        data: byteCode,
        arguments: args,
      });

      const rawTransaction = (
        await account.getAccount().signTransaction({
          data: data.encodeABI(),
          from: account.getAddress(),
          gas: 5913388,
        })
      ).rawTransaction;

      return await this.web3.eth.sendSignedTransaction(rawTransaction);
    } else {
      const accounts = await this.web3.eth.getAccounts();
      const res = await this.__metamaskDeploy({
        byteCode,
        args,
        acc: accounts[0],
        callback,
      });
      this.address = res.contractAddress;
      return res;
    }
  }

  async __metamaskDeploy({ byteCode, args, acc, callback = () => {} }) {
    return new Promise((resolve, reject) => {
      try {
        this.getContract()
          .deploy({
            data: byteCode,
            arguments: args,
          })
          .send({ from: acc })
          .on("confirmation", (confirmationNumber, receipt) => {
            callback(confirmationNumber);
            if (confirmationNumber > 0) {
              resolve(receipt);
            }
          })
          .on("error", (err) => {
            reject(err);
          });
      } catch (err) {
        reject(err);
      }
    });
  }

  async use(contract_json, address) {
    this.json = contract_json;
    this.abi = contract_json.abi;
    this.address = address ? address : this.address;
    this.contract = new this.web3.eth.Contract(contract_json.abi, this.address);
  }

  async getSmartGasPrice() {
    try {
      const baseGasPrice = await this.web3.eth.getGasPrice();
      const latestBlock = await this.web3.eth.getBlock("latest");
      const utilization = (latestBlock.gasUsed / latestBlock.gasLimit) * 100;

      const baseGasPriceBigInt = BigInt(baseGasPrice);

      // Continuous function: multiplier = 1.2 + 0.8 * (utilization/100)^2
      // This creates a smooth curve from 1.2x to 2.0x with accelerated scaling at high utilization
      const utilizationRatio = Math.min(utilization / 100, 1.0); // Cap at 100%
      const multiplierFloat = 1.2 + 0.8 * Math.pow(utilizationRatio, 2);
      const multiplier = Math.round(multiplierFloat * 100); // Convert to integer for BigInt math

      const smartGasPrice = (baseGasPriceBigInt * BigInt(multiplier)) / BigInt(100);
      return smartGasPrice.toString();
    } catch (err) {
      try {
        const fallbackPrice = await this.web3.eth.getGasPrice();
        return ((BigInt(fallbackPrice) * BigInt(200)) / BigInt(100)).toString();
      } catch (fallbackErr) {
        // should be non-blocking, defaulting to 10 gwei
        return '10000000000';
      }
    }
  }

  async send(account, byteCode, value = "0x0", callback = () => {}) {
    return new Promise(async (resolve, reject) => {
      const gasPrice = await this.getSmartGasPrice();

      let tx = {
        data: byteCode,
        from: account.address,
        to: this.address,
        gas: 4430000,
        gasPrice,
        value: value ? value : "0x0",
      };

      let result = await account.signTransaction(tx);
      this.web3.eth
        .sendSignedTransaction(result.rawTransaction)
        .on("confirmation", (confirmationNumber, receipt) => {
          callback(confirmationNumber);
          if (confirmationNumber > 0) {
            resolve(receipt);
          }
        })
        .on("error", (err) => {
          reject(err);
        });
    });
  }

  getContract() {
    return this.contract;
  }

  getABI() {
    return this.abi;
  }

  getJSON() {
    return this.json;
  }

  getAddress() {
    return this.address;
  }
}

module.exports = Contract;
