import IContract from "./IContract";
import Numbers from "../utils/Numbers";
import interfaces from "../interfaces";

const actions: { [key: number]: string } = {
  0: "Upvote",
  1: "Remove Upvote",
  2: "Downvote",
  3: "Remove Downvote",
};

class VotingContract extends IContract {
  constructor(params: any) {
    super({ abi: interfaces.voting, ...params });
    this.contractName = "voting";
  }

  async getMinimumRequiredBalance(): Promise<number> {
    const requiredBalance = await this.params.contract
      .getContract()
      .methods.requiredBalance()
      .call();

    return Numbers.fromDecimalsNumber(requiredBalance, 18);
  }

  async getItemVotes({
    itemId,
  }: {
    itemId: number;
  }): Promise<{ upvotes: number; downvotes: number }> {
    const res = await this.params.contract
      .getContract()
      .methods.getItemVotes(itemId)
      .call();

    return {
      upvotes: Number(res[0]),
      downvotes: Number(res[1]),
    };
  }

  async hasUserVotedItem({
    user,
    itemId,
  }: {
    user: string;
    itemId: number;
  }): Promise<{ upvoted: boolean; downvoted: boolean }> {
    const res = await this.params.contract
      .getContract()
      .methods.hasUserVotedItem(user, itemId)
      .call();

    return {
      upvoted: res[0],
      downvoted: res[1],
    };
  }

  async getUserActions({ user }: { user: string }): Promise<any[]> {
    const events = await this.getEvents("ItemVoteAction", { user });

    return events.map((event: any) => {
      return {
        action:
          actions[
            Numbers.fromBigNumberToInteger(event.returnValues.action, 18)
          ],
        itemId: Numbers.fromBigNumberToInteger(event.returnValues.itemId, 18),
        timestamp: Numbers.fromBigNumberToInteger(
          event.returnValues.timestamp,
          18,
        ),
        transactionHash: event.transactionHash,
      };
    });
  }

  async getUserVotes({ user }: { user: string }): Promise<any> {
    const events = await this.getEvents("ItemVoteAction", { user });

    const eventMap = new Map();

    events.forEach((event: any) => {
      eventMap.set(
        Numbers.fromBigNumberToInteger(event.returnValues.itemId, 18),
        actions[Numbers.fromBigNumberToInteger(event.returnValues.action, 18)],
      );
    });

    const userVotes: {
      [key: number]: { upvoted: boolean; downvoted: boolean };
    } = {};
    [...eventMap].forEach(
      ([itemId, action]) =>
        (userVotes[itemId] = {
          upvoted: action === actions[0],
          downvoted: action === actions[2],
        }),
    );

    return userVotes;
  }

  async upvoteItem({ itemId }: { itemId: number }): Promise<any> {
    return await this.__sendTx(this.getContract().methods.upvoteItem(itemId));
  }

  async downvoteItem({ itemId }: { itemId: number }): Promise<any> {
    return await this.__sendTx(this.getContract().methods.downvoteItem(itemId));
  }

  async removeUpvoteItem({ itemId }: { itemId: number }): Promise<any> {
    return await this.__sendTx(
      this.getContract().methods.removeUpvoteItem(itemId),
    );
  }

  async removeDownvoteItem({ itemId }: { itemId: number }): Promise<any> {
    return await this.__sendTx(
      this.getContract().methods.removeDownvoteItem(itemId),
    );
  }
}

export default VotingContract;
