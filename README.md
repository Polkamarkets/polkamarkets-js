# ![alt tag](https://uploads-ssl.webflow.com/6001b8a9fb88852f468bf865/600f55bddbe2354c1e36e200_Dark.svg)

## Introductions

`polkamarkets-js` is the Polkamarkets' Javascript SDK to integrate Prediction Markets into any dapp.

## Installation

Using [npm](https://www.npmjs.com/):

```bash
npm install "https://github.com/Polkamarkets/polkamarkets-js" --save
```

Using [yarn](https://yarnpkg.com/):

```bash
yarn add https://github.com/Polkamarkets/polkamarkets-js
```

## Usage

### Initializing App

`polkamarkets-js` library initialization is performed in [`Application.js`](https://github.com/Polkamarkets/polkamarkets-js/blob/main/src/Application.js).

You'll need to provide a web3 RPC provider (e.g., Infura for Ethereum dapps)

```javascript
import * as polkamarketsjs from 'polkamarkets-js';

// Moonriver RPC
const web3Provider = 'https://rpc.moonriver.moonbeam.network';

const polkamarkets = new polkamarketsjs.Application({ web3Provider });

// Starting application
polkamarkets.start();

// Connecting wallet
await polkamarkets.login();
```

### Prediction Markets

Once the library is initialized, it's ready to interact with prediction markets smart contracts.

```javascript
const contractAddress = '0xDcBe79f74c98368141798eA0b7b979B9bA54b026';
const contract = polkamarkets.getPredictionMarketContract({ contractAddress });
```

Once initialized, you'll be able to interact with the smart contract.

- Prediction Market Smart Contract: [PredictionMarket.sol](https://github.com/Polkamarkets/polkamarkets-js/blob/main/contracts/PredictionMarket.sol)
- Prediction Market JS Integration: [PredictionMarketContract.js](https://github.com/Polkamarkets/polkamarkets-js/blob/main/src/models/PredictionMarketContract.js)

Here's a few call examples

```javascript
const marketId = 1;
const outcomeId = 2;
const ethAmount = 0.1;

// Fetching all Market Ids
await contract.getMarkets();

// Fetching Market Details
await contract.getMarketData({ marketId });

// Buying Outcome Shares
const mintOutcomeSharesToBuy = await contract.calcBuyAmount({ marketId, outcomeId, ethAmount })
await contract.buy({ marketId, outcomeId, ethAmount, minOutcomeSharesToBuy });

// Selling Outcome Shares
const maxOutcomeSharesToSell = await contract.calcSellAmount({ marketId, outcomeId, ethAmount })
await contract.buy({ marketId, outcomeId, ethAmount, maxOutcomeSharesToSell });

// Claiming Winnings
await contract.claimWinnings({ marketId });

// Fetching portfolio data
await contract.getMyPortfolio();
```

## Contribution

Contributions are welcomed but we ask to red existing code guidelines, specially the code format. Please review [Contributor guidelines][1]

## License

[MIT](https://choosealicense.com/licenses/mit/)

## Notes

The usage of ETH in all methods or params means using the native currency of that blockchain, example BSC in Binance Chain would still be nominated as ETH

[1]: https://github.com/Polkamarkets/polkamarkets-js/blob/main/CONTRIBUTING.md
