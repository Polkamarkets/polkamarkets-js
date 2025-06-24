import ERC20Contract from "./ERC20Contract";
import Numbers from "../utils/Numbers";
import interfaces from "../interfaces";

class FantasyERC20Contract extends ERC20Contract {
  constructor(params: any) {
    super({ abi: interfaces.fantasyerc20, ...params });
  }

  async hasUserClaimedTokens({
    address,
  }: {
    address: string;
  }): Promise<boolean> {
    return await this.params.contract
      .getContract()
      .methods.hasUserClaimedTokens(address)
      .call();
  }

  async tokenAmountToClaim(): Promise<number> {
    const tokenAmountToClaim = Numbers.fromDecimalsNumber(
      await this.params.contract
        .getContract()
        .methods.tokenAmountToClaim()
        .call(),
      this.getDecimals(),
    );

    return tokenAmountToClaim;
  }

  async claimTokens(): Promise<any> {
    return await this.__sendTx(this.getContract().methods.claimTokens());
  }

  async claimAndApproveTokens(): Promise<any> {
    return await this.__sendTx(
      this.getContract().methods.claimAndApproveTokens(),
    );
  }

  async resetBalance(): Promise<any> {
    const address = await this.getMyAccount();
    if (!address) return false;

    const tokenAmountToClaim = await this.tokenAmountToClaim();
    const balance = await this.getTokenAmount(address);

    const amountToBurn =
      balance - tokenAmountToClaim > 0 ? balance - tokenAmountToClaim : 0;

    return await this.burn({ amount: amountToBurn });
  }
}

export default FantasyERC20Contract;
