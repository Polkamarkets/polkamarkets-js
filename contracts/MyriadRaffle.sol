// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";


contract MyriadRaffle is VRFConsumerBaseV2Plus {
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);

    struct RaffleStatus {
        uint256[] randomWords;
        bool exists;
        bool fulfilled;
        bool winnersSelected;
        string ipfsHash;
        string contestName;
        uint256 numEntries;
        uint256 numWinners;
        uint256[] winners;
        mapping(uint256 => bool) winnersMap;
    }
    mapping(uint256 => RaffleStatus) public _raffles; /* requestId --> RaffleStatus */

    uint256 _subscriptionId;
    address _vrfCoordinator = 0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e;
    bytes32 _keyHash =
        0x8472ba59cf7134dfe321f4d61a430c4857e8b19cdd5230b09952a92671c24409;
    uint32 _callbackGasLimit = 100000;
    uint16 _requestConfirmations = 3;
    uint32 _numWords = 1;

    uint256 public lastRequestId;
    uint256[] public requestIds;

    constructor(
        uint256 subscriptionId
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        _subscriptionId = subscriptionId;
    }

    function startRaffle(
        string memory ipfsHash,
        string memory contestName,
        uint256 numEntries,
        uint256 numWinners
    ) external onlyOwner {
        require(numWinners < numEntries, "more winners than entries");

        lastRequestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: _keyHash,
                subId: _subscriptionId,
                requestConfirmations: _requestConfirmations,
                callbackGasLimit: _callbackGasLimit,
                numWords: _numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );
        requestIds.push(lastRequestId);

        RaffleStatus storage r = _raffles[lastRequestId];
        r.exists = true;
        r.ipfsHash = ipfsHash;
        r.contestName = contestName;
        r.numEntries = numEntries;
        r.numWinners = numWinners;

        emit RequestSent(lastRequestId, _numWords);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        require(_raffles[requestId].exists, "request not found");

        _raffles[requestId].fulfilled = true;
        _raffles[requestId].randomWords = randomWords;

        emit RequestFulfilled(requestId, randomWords);
    }

    function selectWinners(uint256 requestId) external onlyOwner {
        uint256 numWinners = _raffles[requestId].numWinners;
        uint256 numEntries = _raffles[requestId].numEntries;

        uint256[] memory winners = new uint256[](numWinners);
        mapping(uint256 => bool) storage winnersMap = _raffles[requestId].winnersMap;

        uint256 i = 0;
        uint256 iWinners = 0;
        while (iWinners < numWinners) {
            uint256 winner = (uint256(keccak256(abi.encode(_raffles[requestId].randomWords, i))) % numEntries) + 1;
            if (!winnersMap[winner]) {
                winners[iWinners] = winner;
                winnersMap[winner] = true;
                ++iWinners;
            }
            ++i;
        }

        _raffles[requestId].winners = winners;
        _raffles[requestId].winnersSelected = true;
    }

    function getRaffle(
        uint256 requestId
    )
        external
        view
        returns (
            uint256[] memory randomWords,
            bool fulfilled,
            bool winnersSelected,
            string memory ipfsHash,
            string memory contestName,
            uint256 numEntries,
            uint256 numWinners,
            uint256[] memory winners
        )
    {
        RaffleStatus storage raffle = _raffles[requestId];

        require(raffle.exists, "raffle not found");
        return (
            raffle.randomWords,
            raffle.fulfilled,
            raffle.winnersSelected,
            raffle.ipfsHash,
            raffle.contestName,
            raffle.numEntries,
            raffle.numWinners,
            raffle.winners
        );
    }
}
