import IContract from "./IContract";
import interfaces from "../interfaces/index";

class PredictionMarketV3QuerierContract extends IContract {
  override contractName: string;
  override getContract: () => any;
  override __sendTx: (...args: any[]) => Promise<any>;

  constructor(params: any) {
    super(params);
    this.contractName = "predictionMarketV3Querier";
    this.getContract = super.getContract;
    this.__sendTx = super.__sendTx;
  }

  async getUserMarketData({
    user,
    marketId,
  }: {
    user: string;
    marketId: number;
  }): Promise<any> {
    return await this.params.contract
      .getContract()
      .methods.getUserMarketData(marketId, user)
      .call();
  }

  async getUserMarketsData({
    user,
    marketIds,
  }: {
    user: string;
    marketIds: number[];
  }): Promise<any[]> {
    return await this.params.contract
      .getContract()
      .methods.getUserMarketsData(marketIds, user)
      .call();
  }

  async getUserAllMarketsData({ user }: { user: string }): Promise<any[]> {
    return await this.params.contract
      .getContract()
      .methods.getUserAllMarketsData(user)
      .call();
  }

  async getMarketPrices({ marketId }: { marketId: number }): Promise<any> {
    return await this.params.contract
      .getContract()
      .methods.getMarketPrices(marketId)
      .call();
  }

  async getMarketsPrices({ marketIds }: { marketIds: number[] }): Promise<any[]> {
    return await this.params.contract
      .getContract()
      .methods.getMarketsPrices(marketIds)
      .call();
  }

  async getMarketERC20Decimals({ marketId }: { marketId: number }): Promise<any> {
    return await this.params.contract
      .getContract()
      .methods.getMarketERC20Decimals(marketId)
      .call();
  }

  async getMarketsERC20Decimals({
    marketIds,
  }: {
    marketIds: number[];
  }): Promise<any[]> {
    return await this.params.contract
      .getContract()
      .methods.getMarketsERC20Decimals(marketIds)
      .call();
  }

  async getMarkets(marketIds: number[]) {
    // ... existing code ...
  }
}

export default PredictionMarketV3QuerierContract;
