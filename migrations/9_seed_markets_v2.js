const PredictionMarketV2 = artifacts.require("PredictionMarketV2");
const realitioLib = require('@reality.eth/reality-eth-lib/formatters/question');
const web3 = require('web3');

module.exports = async function(deployer) {
  const predictionMarket = await PredictionMarketV2.deployed();

  const markets = [
    {
      name: 'Will Bitcoin price be above $100,000 by January 1st 2024?',
      outcomes: ['Yes', 'No'],
      category: 'Crypto;Bitcoin',
      image: 'QmXUiapNZUbxfWpNYMtbT8Xpyk4EdF6gKWa7cw8SBX5gm9',
      closesAt: 1704067200,
    },
    {
      name: 'Market with 3 outcomes',
      outcomes: ['Outcome A', 'Outcome B', 'Outcome C'],
      category: 'Other;Misc',
      image: 'QmdRGv8odwsnafpz49ZayQNhmJzJTaT2kjXrrm6aBMJ1Qw',
      closesAt: 1704067200,
    },
    {
      name: 'Market with 4 outcomes',
      outcomes: ['Outcome A', 'Outcome B', 'Outcome C', 'Outcome D'],
      category: 'Other;Misc',
      image: 'QmdRGv8odwsnafpz49ZayQNhmJzJTaT2kjXrrm6aBMJ1Qw',
      closesAt: 1704067200,
    },
    {
      name: 'Market with 3 outcomes uneven',
      outcomes: ['Outcome A', 'Outcome B', 'Outcome C'],
      category: 'Other;Misc',
      image: 'QmdRGv8odwsnafpz49ZayQNhmJzJTaT2kjXrrm6aBMJ1Qw',
      closesAt: 1704067200,
      distribution: [300000000, 975000000, 1300000000],
    },
    {
      name: 'Market with 10 outcomes',
      outcomes: ['Outcome A', 'Outcome B', 'Outcome C', 'Outcome D', 'Outcome E', 'Outcome F', 'Outcome G', 'Outcome H', 'Outcome I', 'Outcome J'],
      category: 'Other;Misc',
      image: 'QmdRGv8odwsnafpz49ZayQNhmJzJTaT2kjXrrm6aBMJ1Qw',
      closesAt: 1704067200,
    },
    {
      name: 'Market with 32 outcomes',
      outcomes: ['Outcome A', 'Outcome B', 'Outcome C', 'Outcome D', 'Outcome E', 'Outcome F', 'Outcome G', 'Outcome H', 'Outcome I', 'Outcome J', 'Outcome K', 'Outcome L', 'Outcome M', 'Outcome N', 'Outcome O', 'Outcome P', 'Outcome Q', 'Outcome R', 'Outcome S', 'Outcome T', 'Outcome U', 'Outcome V', 'Outcome W', 'Outcome X', 'Outcome Y', 'Outcome Z', 'Outcome AA', 'Outcome BB', 'Outcome CC', 'Outcome DD', 'Outcome EE', 'Outcome FF'],
      category: 'Other;Misc',
      image: 'QmdRGv8odwsnafpz49ZayQNhmJzJTaT2kjXrrm6aBMJ1Qw',
      closesAt: 1704067200,
    },
  ]

  for (const market of markets) {
		const question = realitioLib.encodeText('single-select', market.name, market.outcomes, market.category);

    await predictionMarket.createMarket({
        value: '10000000000000000000',
        closesAt: market.closesAt,
        outcomes: market.outcomes.length,
        token: '0x7895b8d634709dd810e384df27a8c989c907fc4a',
        distribution: market.distribution || [],
        question,
        image: market.image,
        arbitrator: '0x000000000000000000000000000000000000dead',
      });
  }
};
