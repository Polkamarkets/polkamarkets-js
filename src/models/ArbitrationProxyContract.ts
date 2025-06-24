import IContract from "./IContract";
import Numbers from "../utils/Numbers";
import interfaces from "../interfaces";

class ArbitrationProxyContract extends IContract {
  constructor(params: any) {
    super({ abi: interfaces.arbitrationProxy, ...params });
    this.contractName = "arbitrationProxy";
  }

  async getArbitrationRequestsRejected({ questionId }: { questionId: any }) {
    const allEvents = await this.getEvents("RequestRejected");
    const questionEvents = allEvents.filter(
      (event: any) => event.returnValues._questionID === questionId,
    );

    return questionEvents.map((event: any) => ({
      questionId: event.returnValues._questionID,
      requester: event.returnValues._requester,
      maxPrevious: Numbers.fromDecimalsNumber(
        event.returnValues._maxPrevious,
        18,
      ),
      reason: event.returnValues._reason,
    }));
  }
}

export default ArbitrationProxyContract;
