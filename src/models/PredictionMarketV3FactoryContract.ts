import IContract from "./IContract";
import interfaces from "../interfaces/index";
import Numbers from "../utils/Numbers";

class PredictionMarketV3FactoryContract extends IContract {
  constructor(params: any) {
    super({ abi: interfaces.predictionMarketV3Factory, ...params });
    this.contractName = "PredictionMarketV3Factory";
  }

  async getMarkets(): Promise<number[]> {
    const res = await this.getContract!().methods.getMarkets().call();
    return res.map((marketId: any) => Number(Numbers.fromHex(marketId)));
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

  async createMarket({
    value,
    name,
    description = "",
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    token,
    odds = [],
    fee = 0,
    treasuryFee = 0,
    treasury = "0x0000000000000000000000000000000000000000",
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress,
  }: {
    value: number;
    name: string;
    description?: string;
    image: string;
    duration: number;
    oracleAddress: string;
    outcomes: string[];
    category: string;
    token: string;
    odds?: number[];
    fee?: number;
    treasuryFee?: number;
    treasury?: string;
    realitioAddress: string;
    realitioTimeout: number;
    PM3ManagerAddress: string;
  }): Promise<any> {
    const decimals = await this.getTokenDecimals();
    const valueToWei = Numbers.toSmartContractDecimals(value, decimals);
    const title = `${name};${description}`;
    const question = this.encodeQuestion(title, outcomes, category);
    let distribution: string[] = [];

    if (odds.length > 0) {
      if (odds.length !== outcomes.length) {
        throw new Error("Odds and outcomes must have the same length");
      }

      const oddsSum = odds.reduce((a: number, b: number) => a + b, 0);
      if (oddsSum < 99.9 || oddsSum > 100.1) {
        throw new Error("Odds must sum 100");
      }

      distribution = this.calcDistribution({ odds });
    }

    return await this.__sendTx!(
      this.getContract!().methods.createMarket({
        value: valueToWei,
        closesAt: duration,
        outcomes: outcomes.length,
        token,
        distribution,
        question,
        image,
        arbitrator: oracleAddress,
        fee: Numbers.toSmartContractDecimals(fee, 18),
        treasuryFee: Numbers.toSmartContractDecimals(treasuryFee, 18),
        treasury,
        realitio: realitioAddress,
        realitioTimeout,
        manager: PM3ManagerAddress,
      }),
    );
  }

  private encodeQuestion(
    title: string,
    outcomes: string[],
    category: string,
  ): string {
    // Simple encoding - in real implementation this would use realitio library
    return JSON.stringify({
      title,
      type: "single-select",
      outcomes,
      category,
    });
  }

  private calcDistribution({ odds }: { odds: number[] }): string[] {
    return odds.map((odd) => Numbers.toSmartContractDecimals(odd, 18));
  }

  private async getTokenDecimals(): Promise<number> {
    // This would typically call an ERC20 contract to get decimals
    return 18; // Default to 18 decimals
  }
}

export default PredictionMarketV3FactoryContract;
