import Web3 from "web3";

interface TransactionData {
  data?: string;
  from: string;
  to: string;
  gas: number;
  value?: string;
}

interface SignedTransaction {
  rawTransaction?: string;
}

interface TransactionReceipt {
  transactionHash: string;
  blockNumber: number;
  gasUsed: number;
  status: boolean;
}

interface AccountData {
  address: string;
  privateKey: string;
  signTransaction: (tx: TransactionData) => Promise<SignedTransaction>;
}

class Account {
  private web3: Web3;
  private account: AccountData;

  constructor(web3: Web3, account: AccountData) {
    this.web3 = web3;
    this.account = account;
  }

  async getBalance(): Promise<string> {
    const wei = await this.web3.eth.getBalance(this.getAddress());
    return this.web3.utils.fromWei(wei, "ether");
  }

  getAddress(): string {
    return this.account.address;
  }

  getPrivateKey(): string {
    return this.account.privateKey;
  }

  getAccount(): AccountData {
    return this.account;
  }

  async sendEther(
    amount: string,
    address: string,
    data: string | null = null,
  ): Promise<TransactionReceipt> {
    const tx: TransactionData = {
      data: data || undefined,
      from: this.getAddress(),
      to: address,
      gas: 443000,
      value: amount,
    };
    const result: SignedTransaction = await this.account.signTransaction(tx);
    if (!result.rawTransaction) {
      throw new Error("Transaction signing failed");
    }
    const transaction: TransactionReceipt =
      await this.web3.eth.sendSignedTransaction(result.rawTransaction);
    return transaction;
  }
}

export default Account;
