![alt tag](https://uploads-ssl.webflow.com/6001b8a9fb88852f468bf865/600f55bddbe2354c1e36e200_Dark.svg)

## Introductions

`polkamarkets-js` is the Polkamarkets Javascript SDK to integrate Prediction Markets into any dapp.

## Installation

Using [npm](https://www.npmjs.com/):

```bash
npm install "polkamarkets-js" --save
```

Using [yarn](https://yarnpkg.com/):

```bash
yarn add polkamarkets-js
```

## Usage

### Initializing App

Polkamarkets uses [`bepro-js`](https://github.com/bepronetwork/bepro-js/tree/feature/prediction-markets) for the web3 EVM integration.

You'll need to provide a web3 RPC provider (e.g., Infura for Ethereum dapps)

```javascript
import Polkamarkets from 'polkamarkets-js';

// Moonriver RPC
const web3Provider = 'https://rpc.moonriver.moonbeam.network';

// Starting application
const polkamarkets = new Polkamarkets(web3Provider);

// Connecting wallet
await polkamarkets.login();

// Fetching connected address
const balance = await polkamarkets.getAddress();

// Fetching address balance
const balance = await polkamarkets.getBalance();
```

### Prediction Markets

Once the library is initialized, it's ready to interact with prediction markets smart contracts.

```javascript
const contractAddress = '0xDcBe79f74c98368141798eA0b7b979B9bA54b026';
polkamarkets.getPredictionMarketContract(contractAddress);
```

Once initialized, you'll be able to interact with the smart contract.

- Prediction Market Smart Contract: [PredictionMarket.sol](https://github.com/bepronetwork/bepro-js/blob/feature/prediction-markets/contracts/PredictionMarket.sol)
- Prediction Market JS Integration: [PredictionMarketContract.js](https://github.com/bepronetwork/bepro-js/blob/feature/prediction-markets/src/models/PredictionMarketContract.js)

Here's a few call examples

```javascript
const marketId = 1;
const outcomeId = 0;
const ethAmount = 0.1;

// Fetching Market Details
await polkamarkets.getMarketData(marketId);

// Buying Outcome Shares
const mintOutcomeSharesToBuy = await polkamarkets.calcBuyAmount(marketId, outcomeId, ethAmount)
await polkamarkets.buy(marketId, outcomeId, ethAmount, minOutcomeSharesToBuy);

// Selling Outcome Shares
const maxOutcomeSharesToSell = await polkamarkets.calcSellAmount(marketId, outcomeId, ethAmount)
await polkamarkets.sell(marketId, outcomeId, ethAmount, maxOutcomeSharesToSell);

// Claiming Winnings
await polkamarkets.claimWinnings(marketId);

// Fetching portfolio data
await polkamarkets.getPortfolio();
```

## Contribution

Contributions are welcomed but we ask to red existing code guidelines, specially the code format. Please review [Contributor guidelines][1]

## License

[MIT](https://choosealicense.com/licenses/mit/)

## Notes

The usage of ETH in all methods or params means using the native currency of that blockchain, example BSC in Binance Chain would still be nominated as ETH

[1]: https://github.com/bepronetwork/bepro-js/blob/master/CONTRIBUTING.md
