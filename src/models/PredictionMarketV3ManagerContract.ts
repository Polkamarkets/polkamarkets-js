import IContract from "./IContract";
import Numbers from "../utils/Numbers";
import interfaces from "../interfaces/index";

interface Land {
  token: string;
  active: boolean;
  lockAmount: number;
  lockUser: string;
  realitio: string;
}

class PredictionMarketV3ManagerContract extends IContract {
  constructor(params: any) {
    super({ abi: interfaces.predictionV3Manager, ...params });
    this.contractName = "PredictionMarketV3Manager";
  }

  async getLandById({ id }: { id: string }): Promise<Land> {
    const token = await this.getContract!().methods.landTokens(id).call();
    return await this.getLandByAddress({ token });
  }

  async getLandByAddress({ token }: { token: string }): Promise<Land> {
    const res = await this.getContract!().methods.lands(token).call();
    return {
      token: res.token,
      active: res.active,
      lockAmount: Numbers.fromDecimalsNumber(res.lockAmount, 18),
      lockUser: res.lockUser,
      realitio: res.realitio,
    };
  }

  async getLandTokensLength(): Promise<number> {
    const index = await this.getContract!().methods.landTokensLength().call();
    return parseInt(index);
  }

  async isAllowedToCreateMarket({
    token,
    user,
  }: {
    token: string;
    user: string;
  }): Promise<boolean> {
    return await this.params.contract
      .getContract()
      .methods.isAllowedToCreateMarket(token, user)
      .call();
  }

  async isAllowedToResolveMarket({
    token,
    user,
  }: {
    token: string;
    user: string;
  }): Promise<boolean> {
    return await this.params.contract
      .getContract()
      .methods.isAllowedToResolveMarket(token, user)
      .call();
  }

  async isAllowedToEditMarket({
    token,
    user,
  }: {
    token: string;
    user: string;
  }): Promise<boolean> {
    return await this.params.contract
      .getContract()
      .methods.isAllowedToEditMarket(token, user)
      .call();
  }

  async isIERC20TokenSocial({ token }: { token: string }): Promise<boolean> {
    // Note: 'user' param is missing in the original, but used in the call. Adjust as needed.
    return await this.params.contract
      .getContract()
      .methods.isIERC20TokenSocial(token)
      .call();
  }

  async isLandAdmin({
    token,
    user,
  }: {
    token: string;
    user: string;
  }): Promise<boolean> {
    return await this.params.contract
      .getContract()
      .methods.isLandAdmin(token, user)
      .call();
  }

  async lockAmount(): Promise<number> {
    const amount = await this.params.contract
      .getContract()
      .methods.lockAmount()
      .call();
    // TODO: fetch ERC20 decimals
    return Numbers.fromDecimalsNumber(amount, 18);
  }

  async lockToken(): Promise<string> {
    return await this.params.contract.getContract().methods.token().call();
  }

  async updateLockAmount({ amount }: { amount: number }): Promise<any> {
    return await this.__sendTx!(
      this.getContract!().methods.updateLockAmount(
        Numbers.toSmartContractDecimals(amount, 18),
      ),
    );
  }

  async createLand({
    name,
    symbol,
    tokenAmountToClaim,
    tokenToAnswer,
  }: {
    name: string;
    symbol: string;
    tokenAmountToClaim: number;
    tokenToAnswer: string;
  }): Promise<any> {
    return await this.__sendTx!(
      this.getContract!().methods.createLand(
        name,
        symbol,
        Numbers.toSmartContractDecimals(tokenAmountToClaim, 18),
        tokenToAnswer,
      ),
    );
  }

  async disableLand({ token }: { token: string }): Promise<any> {
    return await this.__sendTx!(this.getContract!().methods.disableLand(token));
  }

  async enableLand({ token }: { token: string }): Promise<any> {
    return await this.__sendTx!(this.getContract!().methods.enableLand(token));
  }

  async unlockOffsetFromLand({ token }: { token: string }): Promise<any> {
    return await this.__sendTx!(
      this.getContract!().methods.unlockOffsetFromLand(token),
    );
  }

  async addAdminToLand({
    token,
    user,
  }: {
    token: string;
    user: string;
  }): Promise<any> {
    return await this.__sendTx!(
      this.getContract!().methods.addAdminToLand(token, user),
    );
  }

  async removeAdminFromLand({
    token,
    user,
  }: {
    token: string;
    user: string;
  }): Promise<any> {
    return await this.__sendTx!(
      this.getContract!().methods.removeAdminFromLand(token, user),
    );
  }
}

export default PredictionMarketV3ManagerContract;
