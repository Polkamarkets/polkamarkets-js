import interfaces from "../interfaces/index";
import IContract from "./IContract";
import Numbers from "../utils/Numbers";

class WETH9Contract extends IContract {
  constructor(params: any) {
    super({ abi: interfaces.weth, ...params });
    this.contractName = "weth";
  }

  getDecimals(): number {
    return 18;
  }

  async totalSupply(): Promise<number> {
    const supply = await this.getContract().methods.totalSupply().call();
    return Number(Numbers.fromDecimals(supply, this.getDecimals()));
  }

  async balanceOf({ address }: { address: string }): Promise<number> {
    return Numbers.fromDecimalsNumber(
      await this.getContract().methods.balanceOf(address).call(),
      this.getDecimals(),
    );
  }

  async isApproved({
    address,
    amount,
    spenderAddress,
  }: {
    address: string;
    amount: number;
    spenderAddress: string;
  }): Promise<boolean> {
    const approvedAmount = Numbers.fromDecimals(
      await this.getContract()
        .methods.allowance(address, spenderAddress)
        .call(),
      this.getDecimals(),
    );
    return Number(approvedAmount) >= amount;
  }

  async approve({
    address,
    amount,
    callback,
  }: {
    address: string;
    amount: number;
    callback?: (confirmationNumber: number) => void;
  }): Promise<any> {
    const amountWithDecimals = Numbers.toSmartContractDecimals(
      amount,
      this.getDecimals(),
    );
    return await this.__sendTx(
      this.getContract().methods.approve(address, amountWithDecimals),
      undefined,
      undefined,
      callback,
    );
  }

  async deposit({
    amount,
    callback,
  }: {
    amount: number;
    callback?: (confirmationNumber: number) => void;
  }): Promise<any> {
    const amountWithDecimals = Numbers.toSmartContractDecimals(
      amount,
      this.getDecimals(),
    );
    return await this.__sendTx(
      this.getContract().methods.deposit(),
      false,
      amountWithDecimals,
      callback,
    );
  }

  async withdraw({
    amount,
    callback,
  }: {
    amount: number;
    callback?: (confirmationNumber: number) => void;
  }): Promise<any> {
    const amountWithDecimals = Numbers.toSmartContractDecimals(
      amount,
      this.getDecimals(),
    );
    return await this.__sendTx(
      this.getContract().methods.withdraw(amountWithDecimals),
      undefined,
      undefined,
      callback,
    );
  }
}

export default WETH9Contract;
