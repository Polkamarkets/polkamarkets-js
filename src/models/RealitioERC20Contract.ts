import interfaces from "../interfaces/index";
import IContract from "./IContract";

class RealitioERC20Contract extends IContract {
  constructor(params: any) {
    super({ abi: interfaces.realitio, ...params });
    this.contractName = "realityETH_ERC20";
  }

  async askQuestion({
    templateId,
    question,
    arbitrator,
    timeout,
    openingTs,
    nonce,
    minBond,
    token,
  }: {
    templateId: number;
    question: string;
    arbitrator: string;
    timeout: number;
    openingTs: number;
    nonce: number;
    minBond: number;
    token: string;
  }): Promise<any> {
    return await this.__sendTx!(
      this.getContract!().methods.askQuestion(
        templateId,
        question,
        arbitrator,
        timeout,
        openingTs,
        nonce,
        minBond,
        token,
      ),
    );
  }
}

export default RealitioERC20Contract;
