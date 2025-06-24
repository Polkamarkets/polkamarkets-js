import interfaces from "../interfaces/index";
import IContract from "./IContract";
import Numbers from "../utils/Numbers";
import { AllowanceArgs } from "../types/contracts";

class ERC20Contract extends IContract {
  constructor(params: any, abi?: any) {
    super({ ...params, abi: params.abi || abi || interfaces.ierc20 });
    this.contractName = "erc20";
  }

  override async __assert() {
    await super.__assert();
    this.params.decimals = await this.getDecimalsAsync();
  }

  async transferTokenAmount({
    toAddress,
    tokenAmount,
  }: {
    toAddress: string;
    tokenAmount: number;
  }): Promise<any> {
    const amountWithDecimals = Numbers.toSmartContractDecimals(
      tokenAmount,
      this.getDecimals(),
    );
    return await this.__sendTx(
      this.getContract().methods.transfer(toAddress, amountWithDecimals),
    );
  }

  async getTokenAmount(address: string): Promise<number> {
    const amount = await this.getContract().methods.balanceOf(address).call();
    return Number(Numbers.fromDecimals(amount, this.getDecimals()));
  }

  async totalSupply(): Promise<number> {
    const supply = await this.getContract().methods.totalSupply().call();
    return Number(Numbers.fromDecimals(supply, this.getDecimals()));
  }

  getABI() {
    return this.params.contract;
  }

  getDecimals(): number {
    return this.params.decimals;
  }

  async getDecimalsAsync(): Promise<number> {
    return await this.getContract().methods.decimals().call();
  }

  async balanceOf({ address }: { address: string }): Promise<number> {
    const decimals = this.getDecimals() || (await this.getDecimalsAsync());
    return Numbers.fromDecimalsNumber(
      await this.getContract().methods.balanceOf(address).call(),
      decimals,
    );
  }

  async allowance({ owner, spender }: AllowanceArgs): Promise<number> {
    const allowance = await this.getContract()
      .methods.allowance(owner, spender)
      .call();
    return Number(Numbers.fromDecimals(allowance, this.getDecimals() || 18));
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
      this.getDecimals() || (await this.getDecimalsAsync()),
    );
    return await this.__sendTx(
      this.getContract().methods.approve(address, amountWithDecimals),
      undefined,
      undefined,
      callback,
    );
  }

  async burn({ amount }: { amount: number }): Promise<any> {
    const amountWithDecimals = Numbers.toSmartContractDecimals(
      amount,
      this.getDecimals(),
    );
    return await this.__sendTx(
      this.getContract().methods.burn(amountWithDecimals),
      false,
    );
  }

  async mint({
    address,
    amount,
  }: {
    address: string;
    amount: number;
  }): Promise<any> {
    const amountWithDecimals = Numbers.toSmartContractDecimals(
      amount,
      this.getDecimals(),
    );
    return await this.__sendTx(
      this.getContract().methods.mint(address, amountWithDecimals),
      false,
    );
  }

  async burnEvents({ address }: { address: string }): Promise<any[]> {
    const events = await this.getEvents("Transfer", {
      from: address,
      to: "0x0000000000000000000000000000000000000000",
    });

    return await Promise.all(
      events.map(async (event: any) => {
        const block = await this.getBlock(event.blockNumber);

        return {
          ...event,
          timestamp: block.timestamp,
        };
      }),
    );
  }

  async name(): Promise<string> {
    return await this.getContract().methods.name().call();
  }

  async symbol(): Promise<string> {
    return await this.getContract().methods.symbol().call();
  }

  async paused(): Promise<boolean> {
    return await this.getContract().methods.paused().call();
  }

  async getTokenInfo(): Promise<{
    name: string;
    address: string;
    ticker: string;
    decimals: number;
  }> {
    return {
      name: await this.name(),
      address: this.getAddress(),
      ticker: await this.symbol(),
      decimals: await this.getDecimalsAsync(),
    };
  }
}

export default ERC20Contract;
