import IContract from "./IContract";
import Numbers from "../utils/Numbers";
import interfaces from "../interfaces";

class ArbitrationContract extends IContract {
  constructor(params: any) {
    super({ abi: interfaces.arbitration, ...params });
    this.contractName = "arbitration";
  }

  async getDisputeFee({ questionId }: { questionId: any }) {
    const fee = await this.params.contract
      .getContract()
      .methods.getDisputeFee(questionId)
      .call();

    return Numbers.fromDecimalsNumber(fee, 18);
  }

  async getArbitrationDisputeId({ questionId }: { questionId: any }) {
    const allEvents = await this.getEvents("ArbitrationCreated");
    const questionEvents = allEvents.filter(
      (event) => event.returnValues._questionID === questionId,
    );

    if (questionEvents.length === 0) return null;

    return Number(questionEvents[0].returnValues._disputeID);
  }

  async getArbitrationRequests({ questionId }: { questionId: any }) {
    const allEvents = await this.getEvents("ArbitrationRequested");
    const questionEvents = allEvents.filter(
      (event) => event.returnValues._questionID === questionId,
    );

    return questionEvents.map((event) => ({
      questionId: event.returnValues._questionID,
      requester: event.returnValues._requester,
      maxPrevious: Numbers.fromDecimalsNumber(
        event.returnValues._maxPrevious,
        18,
      ),
    }));
  }

  async requestArbitration({
    questionId,
    bond,
  }: {
    questionId: any;
    bond: any;
  }) {
    const fee = await this.params.contract
      .getContract()
      .methods.getDisputeFee(questionId)
      .call();
    const maxPrevious = Numbers.toSmartContractDecimals(bond, 18);

    return await this.__sendTx(
      this.getContract().methods.requestArbitration(questionId, maxPrevious),
      false,
      fee,
    );
  }
}

export default ArbitrationContract;
