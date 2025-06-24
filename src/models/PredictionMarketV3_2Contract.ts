import PredictionMarketV3Contract from "./PredictionMarketV3Contract";
import PredictionMarketV3QuerierContract from "./PredictionMarketV3QuerierContract";
import Numbers from "../utils/Numbers";
import realitioLib from "@reality.eth/reality-eth-lib/formatters/question";

class PredictionMarketV3_2Contract extends PredictionMarketV3Contract {
  override querier?: PredictionMarketV3QuerierContract;
  override marketDecimals: any;

  constructor(params: any) {
    super(params);
    this.contractName = "predictionMarketV3_2";
    if (params.defaultDecimals) {
      this.defaultDecimals = params.defaultDecimals;
    }
    if (params.querierContractAddress) {
      this.querier = new PredictionMarketV3QuerierContract({
        ...this.params,
        contractAddress: params.querierContractAddress,
      });
    }
    this.marketDecimals = {};
  }

  override async prepareCreateMarketDescription({
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
  }: any) {
    const marketResolutionDate = (await import("moment"))
      .default()
      .add(duration, "days");
    const question = realitioLib.questionToJSON(
      "single-select",
      `${name};${description}`,
      outcomes,
      category,
    );

    let distribution: number[] = [];

    if (odds.length > 0) {
      const totalInverse = odds.reduce(
        (acc: number, o: number) => acc + 1 / o,
        0,
      );
      distribution = odds.map((o: number) => (1 / o / totalInverse) * 100);
    } else {
      distribution = outcomes.map(() => 100 / outcomes.length);
    }

    const outcomesShares = distribution.map((d: number) =>
      Numbers.toSmartContractDecimals((value * d) / 100, 18),
    );
    const liquidityFee = Numbers.toSmartContractDecimals(fee, 18);
    const treasuryFeePercentage = Numbers.toSmartContractDecimals(
      treasuryFee,
      18,
    );

    return {
      question,
      image,
      outcomesShares,
      liquidityFee,
      marketResolutionDate,
      treasury,
      treasuryFeePercentage,
      token,
      oracleAddress,
    };
  }

  override async mintAndCreateMarket({
    value,
    name,
    description,
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    token,
    odds,
    fee,
    treasuryFee,
    treasury,
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress,
    salt,
  }: any) {
    const desc = await this.prepareCreateMarketDescription({
      value,
      name,
      description,
      image,
      duration,
      oracleAddress,
      outcomes,
      category,
      token,
      odds,
      fee,
      treasuryFee,
      treasury,
    });

    return await this.__sendTx(
      this.getContract().methods.mintAndCreateMarket({
        ...desc,
        realitio: realitioAddress,
        realitioTimeout,
        manager: PM3ManagerAddress,
        salt,
      }),
    );
  }

  override async createMarket({
    value,
    name,
    description,
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    token,
    odds,
    fee,
    treasuryFee,
    treasury,
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress,
    salt,
  }: any) {
    const desc = await this.prepareCreateMarketDescription({
      value,
      name,
      description,
      image,
      duration,
      oracleAddress,
      outcomes,
      category,
      token,
      odds,
      fee,
      treasuryFee,
      treasury,
    });

    return await this.__sendTx(
      this.getContract().methods.createMarket({
        ...desc,
        realitio: realitioAddress,
        realitioTimeout,
        manager: PM3ManagerAddress,
        salt,
      }),
    );
  }

  override async createMarketWithETH({
    value,
    name,
    description,
    image,
    duration,
    oracleAddress,
    outcomes,
    category,
    token,
    odds,
    fee,
    treasuryFee,
    treasury,
    realitioAddress,
    realitioTimeout,
    PM3ManagerAddress,
    salt,
  }: any) {
    const desc = await this.prepareCreateMarketDescription({
      value,
      name,
      description,
      image,
      duration,
      oracleAddress,
      outcomes,
      category,
      token,
      odds,
      fee,
      treasuryFee,
      treasury,
    });

    return await this.__sendTx(
      this.getContract().methods.createMarketWithETH({
        ...desc,
        realitio: realitioAddress,
        realitioTimeout,
        manager: PM3ManagerAddress,
        salt,
      }),
      false,
      value,
    );
  }

  async adminPauseMarket({ marketId }: { marketId: any }) {
    return await this.__sendTx(
      this.getContract().methods.adminPauseMarket(marketId),
      false
    );
  }

  async adminUnpauseMarket({ marketId }: { marketId: any }) {
    return await this.__sendTx(
      this.getContract().methods.adminUnpauseMarket(marketId),
      false
    );
  }

  async getMarketFees({ marketId }: { marketId: any }) {
    return await this.getContract().methods.getMarketFees(marketId).call();
  }
}

export default PredictionMarketV3_2Contract;
