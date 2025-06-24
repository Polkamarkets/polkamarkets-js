import Web3 from "web3";
import Account from "./Account";

interface ContractJSON {
  abi: any[];
  [key: string]: any;
}

interface DeployOptions {
  data: string;
  arguments: any[];
}

interface TransactionOptions {
  data: string;
  from: string;
  to: string;
  gas: number;
  gasPrice?: string;
  value?: string;
}

interface TransactionReceipt {
  transactionHash: string;
  blockNumber: number;
  gasUsed: number;
  status: boolean;
  contractAddress?: string;
}

interface MetamaskDeployOptions {
  byteCode: string;
  args: any[];
  acc: string;
  callback?: (confirmationNumber: number) => void;
}

class Contract {
  private web3: Web3;
  private json: ContractJSON;
  private abi: any[];
  private address: string;
  private contract: any;

  constructor(web3: Web3, contract_json: ContractJSON, address: string) {
    this.web3 = web3;
    this.json = contract_json;
    this.abi = contract_json.abi;
    this.address = address;
    this.contract = new web3.eth.Contract(contract_json.abi, address);
  }

  async deploy(
    account: Account | null,
    abi: any[],
    byteCode: string,
    args: any[] = [],
    callback: () => void = () => {},
  ): Promise<TransactionReceipt> {
    this.contract = new this.web3.eth.Contract(abi);
    if (account) {
      const data = this.contract.deploy({
        data: byteCode,
        arguments: args,
      } as DeployOptions);

      const rawTransaction = (
        await account.getAccount().signTransaction({
          data: data.encodeABI(),
          from: account.getAddress(),
          to: "",
          gas: 5913388,
          value: "0x0",
        })
      ).rawTransaction;

      if (!rawTransaction) {
        throw new Error("Transaction signing failed");
      }

      return await this.web3.eth.sendSignedTransaction(rawTransaction);
    } else {
      const accounts = await this.web3.eth.getAccounts();
      const res = await this.__metamaskDeploy({
        byteCode,
        args,
        acc: accounts[0],
        callback,
      });
      this.address = res.contractAddress || this.address;
      return res;
    }
  }

  private async __metamaskDeploy({
    byteCode,
    args,
    acc,
    callback = () => {},
  }: MetamaskDeployOptions): Promise<TransactionReceipt> {
    return new Promise((resolve, reject) => {
      try {
        this.getContract()
          .deploy({
            data: byteCode,
            arguments: args,
          } as DeployOptions)
          .send({ from: acc })
          .on(
            "confirmation",
            (confirmationNumber: number, receipt: TransactionReceipt) => {
              callback(confirmationNumber);
              if (confirmationNumber > 0) {
                resolve(receipt);
              }
            },
          )
          .on("error", (err: Error) => {
            reject(err);
          });
      } catch (err) {
        reject(err);
      }
    });
  }

  async use(contract_json: ContractJSON, address?: string): Promise<void> {
    this.json = contract_json;
    this.abi = contract_json.abi;
    this.address = address ? address : this.address;
    this.contract = new this.web3.eth.Contract(contract_json.abi, this.address);
  }

  async send(
    account: Account,
    byteCode: string,
    value: string = "0x0",
    callback: () => void = () => {},
  ): Promise<TransactionReceipt> {
    return new Promise(async (resolve, reject) => {
      let gasPrice: string;
      try {
        const currentGasPrice = await this.web3.eth.getGasPrice();
        gasPrice = (Number(currentGasPrice) * 2).toString();
      } catch (err) {
        // should be non-blocking, defaulting to 10 gwei
        gasPrice = "10000000000";
      }

      const tx: TransactionOptions = {
        data: byteCode,
        from: account.getAddress(),
        to: this.address,
        gas: 4430000,
        gasPrice,
        value: value ? value : "0x0",
      };

      const result = await account.getAccount().signTransaction(tx);
      if (!result.rawTransaction) {
        reject(new Error("Transaction signing failed"));
        return;
      }

      this.web3.eth
        .sendSignedTransaction(result.rawTransaction)
        .on(
          "confirmation",
          (confirmationNumber: number, receipt: TransactionReceipt) => {
            callback();
            if (confirmationNumber > 0) {
              resolve(receipt);
            }
          },
        )
        .on("error", (err: Error) => {
          reject(err);
        });
    });
  }

  getContract(): any {
    return this.contract;
  }

  getABI(): any[] {
    return this.abi;
  }

  getJSON(): ContractJSON {
    return this.json;
  }

  getAddress(): string {
    return this.address;
  }
}

export default Contract;
