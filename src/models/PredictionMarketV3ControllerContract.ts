import IContract from "./IContract";
import interfaces from "../interfaces/index";
import Numbers from "../utils/Numbers";

class PredictionMarketV3ControllerContract extends IContract {
  constructor(params: any) {
    super({ abi: interfaces.predictionV3Controller, ...params });
    this.contractName = "PredictionMarketV3Controller";
  }

  async getMarketData({ marketId }: { marketId: number }): Promise<any> {
    const marketData = await this.getContract!()
      .methods.getMarketData(marketId)
      .call();
    return {
      closeDateTime: marketData[1],
      state: parseInt(marketData[0]),
      oracleAddress: marketData[2],
      liquidity: Numbers.fromDecimalsNumber(marketData[3], 18),
      outcomeIds: marketData[4].map((outcomeId: any) =>
        Numbers.fromBigNumberToInteger(outcomeId, 18),
      ),
    };
  }

  async getMarkets(): Promise<number[]> {
    const res = await this.getContract!().methods.getMarkets().call();
    return res.map((marketId: any) => Number(Numbers.fromHex(marketId)));
  }

  async getMarketOutcomes({ marketId }: { marketId: number }): Promise<any[]> {
    return await this.getContract!().methods.getMarketOutcomes(marketId).call();
  }

  async getMarketOutcomeData({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }): Promise<any> {
    const outcomeData = await this.getContract!()
      .methods.getMarketOutcomeData(marketId, outcomeId)
      .call();
    return {
      liquidity: Numbers.fromDecimalsNumber(outcomeData[0], 18),
      price: Numbers.fromDecimalsNumber(outcomeData[1], 18),
    };
  }

  async getMarketOutcomePrice({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }): Promise<number> {
    const price = await this.getContract!()
      .methods.getMarketOutcomePrice(marketId, outcomeId)
      .call();
    return Numbers.fromDecimalsNumber(price, 18);
  }

  async getMarketOutcomeLiquidity({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }): Promise<number> {
    const liquidity = await this.getContract!()
      .methods.getMarketOutcomeLiquidity(marketId, outcomeId)
      .call();
    return Numbers.fromDecimalsNumber(liquidity, 18);
  }

  async getMarketState({ marketId }: { marketId: number }): Promise<number> {
    const state = await this.getContract!()
      .methods.getMarketState(marketId)
      .call();
    return parseInt(state);
  }

  async getMarketCloseTime({
    marketId,
  }: {
    marketId: number;
  }): Promise<number> {
    const closeTime = await this.getContract!()
      .methods.getMarketCloseTime(marketId)
      .call();
    return parseInt(closeTime);
  }

  async getMarketOracle({ marketId }: { marketId: number }): Promise<string> {
    return await this.getContract!().methods.getMarketOracle(marketId).call();
  }

  async getMarketToken({ marketId }: { marketId: number }): Promise<string> {
    return await this.getContract!().methods.getMarketToken(marketId).call();
  }

  async getMarketQuestion({ marketId }: { marketId: number }): Promise<string> {
    return await this.getContract!().methods.getMarketQuestion(marketId).call();
  }

  async getMarketImage({ marketId }: { marketId: number }): Promise<string> {
    return await this.getContract!().methods.getMarketImage(marketId).call();
  }

  async getMarketCategory({ marketId }: { marketId: number }): Promise<string> {
    return await this.getContract!().methods.getMarketCategory(marketId).call();
  }

  async getMarketFee({ marketId }: { marketId: number }): Promise<number> {
    const fee = await this.getContract!().methods.getMarketFee(marketId).call();
    return Numbers.fromDecimalsNumber(fee, 18);
  }

  async getMarketTreasuryFee({
    marketId,
  }: {
    marketId: number;
  }): Promise<number> {
    const treasuryFee = await this.getContract!()
      .methods.getMarketTreasuryFee(marketId)
      .call();
    return Numbers.fromDecimalsNumber(treasuryFee, 18);
  }

  async getMarketTreasury({ marketId }: { marketId: number }): Promise<string> {
    return await this.getContract!().methods.getMarketTreasury(marketId).call();
  }

  async getMarketRealitio({ marketId }: { marketId: number }): Promise<string> {
    return await this.getContract!().methods.getMarketRealitio(marketId).call();
  }

  async getMarketRealitioTimeout({
    marketId,
  }: {
    marketId: number;
  }): Promise<number> {
    const timeout = await this.getContract!()
      .methods.getMarketRealitioTimeout(marketId)
      .call();
    return parseInt(timeout);
  }

  async getMarketManager({ marketId }: { marketId: number }): Promise<string> {
    return await this.getContract!().methods.getMarketManager(marketId).call();
  }

  async getMarketOutcomeIds({
    marketId,
  }: {
    marketId: number;
  }): Promise<number[]> {
    const outcomeIds = await this.getContract!()
      .methods.getMarketOutcomeIds(marketId)
      .call();
    return outcomeIds.map((outcomeId: any) =>
      Numbers.fromBigNumberToInteger(outcomeId, 18),
    );
  }

  async getMarketOutcomeCount({
    marketId,
  }: {
    marketId: number;
  }): Promise<number> {
    const count = await this.getContract!()
      .methods.getMarketOutcomeCount(marketId)
      .call();
    return parseInt(count);
  }

  async getMarketOutcomeName({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }): Promise<string> {
    return await this.getContract!()
      .methods.getMarketOutcomeName(marketId, outcomeId)
      .call();
  }

  async getMarketOutcomeIndex({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }): Promise<number> {
    const index = await this.getContract!()
      .methods.getMarketOutcomeIndex(marketId, outcomeId)
      .call();
    return parseInt(index);
  }

  async getMarketOutcomeExists({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }): Promise<boolean> {
    return await this.getContract!()
      .methods.getMarketOutcomeExists(marketId, outcomeId)
      .call();
  }

  async getMarketOutcomeTotalSupply({
    marketId,
    outcomeId,
  }: {
    marketId: number;
    outcomeId: number;
  }): Promise<number> {
    const totalSupply = await this.getContract!()
      .methods.getMarketOutcomeTotalSupply(marketId, outcomeId)
      .call();
    return Numbers.fromDecimalsNumber(totalSupply, 18);
  }

  async getMarketOutcomeBalanceOf({
    marketId,
    outcomeId,
    account,
  }: {
    marketId: number;
    outcomeId: number;
    account: string;
  }): Promise<number> {
    const balance = await this.getContract!()
      .methods.getMarketOutcomeBalanceOf(marketId, outcomeId, account)
      .call();
    return Numbers.fromDecimalsNumber(balance, 18);
  }

  async getMarketOutcomeAllowance({
    marketId,
    outcomeId,
    owner,
    spender,
  }: {
    marketId: number;
    outcomeId: number;
    owner: string;
    spender: string;
  }): Promise<number> {
    const allowance = await this.getContract!()
      .methods.getMarketOutcomeAllowance(marketId, outcomeId, owner, spender)
      .call();
    return Numbers.fromDecimalsNumber(allowance, 18);
  }

  async getMarketOutcomeTransfer({
    marketId,
    outcomeId,
    to,
    amount,
  }: {
    marketId: number;
    outcomeId: number;
    to: string;
    amount: number;
  }): Promise<any> {
    const amountToWei = Numbers.toSmartContractDecimals(amount, 18);
    return await this.__sendTx!(
      this.getContract!().methods.getMarketOutcomeTransfer(
        marketId,
        outcomeId,
        to,
        amountToWei,
      ),
    );
  }

  async getMarketOutcomeTransferFrom({
    marketId,
    outcomeId,
    from,
    to,
    amount,
  }: {
    marketId: number;
    outcomeId: number;
    from: string;
    to: string;
    amount: number;
  }): Promise<any> {
    const amountToWei = Numbers.toSmartContractDecimals(amount, 18);
    return await this.__sendTx!(
      this.getContract!().methods.getMarketOutcomeTransferFrom(
        marketId,
        outcomeId,
        from,
        to,
        amountToWei,
      ),
    );
  }

  async getMarketOutcomeApprove({
    marketId,
    outcomeId,
    spender,
    amount,
  }: {
    marketId: number;
    outcomeId: number;
    spender: string;
    amount: number;
  }): Promise<any> {
    const amountToWei = Numbers.toSmartContractDecimals(amount, 18);
    return await this.__sendTx!(
      this.getContract!().methods.getMarketOutcomeApprove(
        marketId,
        outcomeId,
        spender,
        amountToWei,
      ),
    );
  }

  async getMarketOutcomeMint({
    marketId,
    outcomeId,
    to,
    amount,
  }: {
    marketId: number;
    outcomeId: number;
    to: string;
    amount: number;
  }): Promise<any> {
    const amountToWei = Numbers.toSmartContractDecimals(amount, 18);
    return await this.__sendTx!(
      this.getContract!().methods.getMarketOutcomeMint(
        marketId,
        outcomeId,
        to,
        amountToWei,
      ),
    );
  }

  async getMarketOutcomeBurn({
    marketId,
    outcomeId,
    from,
    amount,
  }: {
    marketId: number;
    outcomeId: number;
    from: string;
    amount: number;
  }): Promise<any> {
    const amountToWei = Numbers.toSmartContractDecimals(amount, 18);
    return await this.__sendTx!(
      this.getContract!().methods.getMarketOutcomeBurn(
        marketId,
        outcomeId,
        from,
        amountToWei,
      ),
    );
  }
}

export default PredictionMarketV3ControllerContract;
