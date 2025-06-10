# ![alt tag](https://uploads-ssl.webflow.com/6001b8a9fb88852f468bf865/600f55bddbe2354c1e36e200_Dark.svg)

`polkamarkets-js` is a library providing JavaScript bindings to interact with Polkamarkets smart contracts. It supports functionalities like **wallet connection, ERC-20 approval,** **buying/selling shares,** **claiming winnings**, and more. 

Below is an **introductory guide** to installing and initializing the **polkamarkets-js** library, showing a typical configuration for social login and network details. You can adapt these fields and environment variables to match your own application setup.

---

## Installation

Install the package via npm or yarn:

```bash
# npm
npm install polkamarkets-js

# yarn
yarn add polkamarkets-js
```

---

## Importing the Library

In your code, import all exported modules or the parts you need:

```jsx
import * as polkamarketsjs from 'polkamarkets-js';
```

---

## Initializing Polkamarkets

Below is an example snippet that creates a new Polkamarkets application instance with social login and various network configurations:

```jsx
const polkamarkets = new polkamarketsjs.Application({
  web3Provider,
  web3EventsProvider**,**
  web3PrivateKey
});
```

Once created, `polkamarkets` can be used throughout your app to interact with Polkamarkets smart contracts, handle user logins, track events, and more.

---

## Configuration Fields

The table below describes each field you see in the initialization object above. Many values are derived from environment variables in this example, but you can hardcode them if you prefer.

| Field | Type | Description |
| --- | --- | --- |
| **`web3Provider`** | `string` | Primary Web3 provider endpoint or an instantiated provider object for RPC calls (e.g. MetaMask, Alchemy, Infura). |
| **`web3PrivateKey`** | `string` | (Optional) private key of wallet to use, if you want to bypass wallet/social login authentication |
| **`web3EventsProvider`** | `string` | (Optional) polkamarkets-rpc web3 endpoint specifically for event subscriptions. |

---

## Logging in Polkamarkets-js

After initializing your Polkamarkets instance, you can call other methods (e.g., connecting to the user’s wallet, creating markets, buying/selling outcome shares, adding liquidity, claiming rewards, etc.). These topics can be documented in subsequent sections.

### 1. Connecting Wallet

Before you can check allowances or send transactions, you need to login into the application using the `login` method. This will trigger a wallet popup to authorize the application. If `web3PrivateKey` is sent when initializing polkamarkets this step is not necessary.

```jsx
await service.login(); // triggers polkamarkets to connect user wallet
```

### 2. Getting the User Address

```jsx
const userAddress = await polkamarkets.getAddress();
console.log(`User is logged in as: ${address}`);
```

---

## Prediction Market Contract

Before calling these methods, you'll typically create a `pm` instance from your polkamarkets application object:

```jsx
import * as polkamarketsjs from 'polkamarkets-js';

// Example snippet:
// 1) You've already instantiated `polkamarkets` (see the prior docs).
// 2) Now get the prediction market V3 contract:
const pm = polkamarkets.getPredictionMarketV3Contract({
  contractAddress: '0x1234...',       // actual PM contract
  querierContractAddress: '0xabcd...' // optional, if you have a read-only/querier contract
});

```

PredictionMarket Contract addresses: 

- Staging: [`0x7accb94c8dd59c8e308e83053ee6cdd770714f37`](https://sepolia.abscan.org/address/0x7accb94c8dd59c8e308e83053ee6cdd770714f37)
- Production: [`0x4f4988a910f8ae9b3214149a8ea1f2e4e3cd93cc`](https://abscan.org/address/0x4f4988a910f8ae9b3214149a8ea1f2e4e3cd93cc)

PredictionMarketQuerier Contract addresses: 

- Staging: [`0x05e1ff194c9bb3f04a0ddb7551f4f9e1c441f235`](https://sepolia.abscan.org/address/0x05e1ff194c9bb3f04a0ddb7551f4f9e1c441f235)
- Production: [`0x710F30AbDADB86A33faE984d6678d4Ed31517B18`](https://abscan.org/address/0x710F30AbDADB86A33faE984d6678d4Ed31517B18)

All subsequent calls in this guide assume you have a valid **`pm`** reference.

---

## 1. Buying and Selling

### 1.1 Buying

```jsx
// the following method is used to calculate how many shares the user wants to purchase
const minOutcomeSharesToBuy = await pm.calcBuyAmount({
	marketId,
	outcomeId,
	value
});

await pm.buy({
  marketId,             // e.g. "123"
  outcomeId,            // e.g. 1 (Yes)
  value,                // e.g. 100
  minOutcomeSharesToBuy // slippage protection
  wrapped               // true/false (if using ETH or an ERC20 token)
});
```

### 1.2 Selling

```jsx
// the following method is used to calculate how many shares the user wants to sell
const maxOutcomeSharesToSell = await pm.calcSellAmount({
	marketId,
	outcomeId,
	value
});

await pm.sell(
  marketId,
  outcomeId,
  value,                  // e.g. 50 tokens
  maxOutcomeSharesToSell, // slippage
  wrapped
);
```

## 2. Claim Winnings

### 2.1 Claim Winnings

Once the market is resolved, users can claim their winnings using the following snippet.

```jsx
await pm.claimWinnings({
  marketId,             // e.g. "123"
  wrapped               // true/false (if using ETH or an ERC20 token)
});
```

### 2.2 Claim Voided Shares

If the market is canceled (voided), users can claim their tokens back at closing prices. The following snippet can be used.

```jsx
await pm.claimVoidedOutcomeShares({
  marketId,
  outcomeId,
  wrapped
});
```

## 3. Portfolio

### 3.1 Fetch portfolio

The following method fetches the user’s holdings and claim status for each outcome.

```jsx
const portfolio = await pm.getPortfolio({
	user
});

console.log(portfolio);
// Example response:
// {
//   ..,
//   20: {
//     liquidity: {
//       shares: 1000,
//       price: 0.89035,
//     },
//     outcomes: {
//       0: {
//         shares: 1591.87,
//         price: 0.6281,
//         voidedWinningsToClaim: false,
//         voidedWinningsClaimed: false,
//       },
//       1: {
//         shares: 0,
//         price: 0,
//         voidedWinningsToClaim: false,
//         voidedWinningsClaimed: false,
//       }
//     }
//     claimStatus: {
//       winningsToClaim: false,
//       winningsClaimed: false,
//       liquidityToClaim: false,
//       liquidityClaimed: false,
//       voidedWinningsToClaim: false,
//       voidedWinningsClaimed: false,
//     }
//   },
//   ...
// }
```

## 4. Market Prices

### 4.1 Fetch market prices

The following method fetches the user’s holdings and claim status for each outcome. Prices range from 0 to 1.

```jsx
const prices = await pm.getMarketPrices({
	marketId
});

console.log(prices);
// Example response:
// {
//     "liquidity": 0.6181712323806557,
//     "outcomes": {
//         "0": 0.8930217320508439,
//         "1": 0.10697826794915608
//     }
// }
```

## 5. Prediction Market Querier

A `predictionMarketQuerier` contract can be used in order to avoid making N RPC calls (where N is the number of desired markets) to fetch info such as:

- Market ERC20 decimals
- User market positions
- Market outcome prices

The querier contract receives an array of market IDs and aggregates all the info into one return. You can use it by adding `querierContractAddress` as an argument of the initialization of the PredictionMarketV3 instance (see code [above](https://www.notion.so/Polkamarkets-SDK-1b5c9e49da8280bbaa95f0fd7bfccec4?pvs=21)).

---

## ERC20 Contract

Create an ERC20 contract instance using `polkamarkets.getERC20Contract(...)`. This snippet assumes you’ve already instantiated your `polkamarkets` application:

```jsx
const erc20 = polkamarkets.getERC20Contract({
  contractAddress: '0xYOUR_ERC20_TOKEN_ADDRESS'
});
```

ERC20 Contract addresses: 

- Staging (reach out to Myriad support if you need any of the staging tokens minted to your account):
    - `USDC` - [`0x8820c84FD53663C2e2EA26e7a4c2b79dCc479765`](https://sepolia.abscan.org/address/0x8820c84FD53663C2e2EA26e7a4c2b79dCc479765)
    - `PENGU` - [`0x6ccDDCf494182a3A237ac3f33A303a57961FaF55`](https://sepolia.abscan.org/address/0x6ccddcf494182a3a237ac3f33a303a57961faf55)
    - `PTS` - [`0x58c8b28089a8cc0A9Ad4d79342C5E432452614C0`](https://sepolia.abscan.org/address/0x58c8b28089a8cc0A9Ad4d79342C5E432452614C0)
- Production:
    - `USDC.e` - [`0x84A71ccD554Cc1b02749b35d22F684CC8ec987e1`](https://abscan.org/address/0x84A71ccD554Cc1b02749b35d22F684CC8ec987e1)
    - `PENGU` - [`0x9eBe3A824Ca958e4b3Da772D2065518F009CBa62`](https://abscan.org/address/0x9eBe3A824Ca958e4b3Da772D2065518F009CBa62)
    - `PTS` - [`0xf19609e96187cdaa34cffb96473fac567e547302`](https://abscan.org/address/0xf19609e96187cdaa34cffb96473fac567e547302)

All subsequent calls in this guide assume you have a valid **`erc20`** reference.

---

### 1. Check Approval Status

Checks if the **user** has approved at least `amount` of tokens for `spender`:

```jsx
await erc20.isApproved({
	address: polkamarkets.getAddress(),
  amount,
  spenderAddress
});
```

### 2. Approve

Grants the `spender` contract permission to move up to `amount` tokens on behalf of the user:

```jsx
await erc20.approve({
	address,
	amount
});
```

---

Below there’s an example of a complete flow using abstract mainnet. We’ll:

1. Initialize Polkamarkets with a **web3Provider** and **web3PrivateKey**.
2. Instantiate a Prediction Market V3 contract (`pm`) and an ERC20 contract (`erc20`).
3. Check approval, approve if needed, create a market, buy outcome shares, and finally claim winnings.

---

```jsx
import * as polkamarketsjs from 'polkamarkets-js';

// 1) Initialize polkamarkets
const polkamarkets = new polkamarketsjs.Application({
  web3Provider: 'api.mainnet.abs.xyz',
  web3PrivateKey: '', // add your pk here
});

// 2) Get the Prediction Market V3 contract
const pm = polkamarkets.getPredictionMarketV3Contract({
  contractAddress: '0x4f4988A910f8aE9B3214149A8eA1F2E4e3Cd93CC',   // pmContractAddress
  querierContractAddress: '0x710f30abdadb86a33fae984d6678d4ed31517b18' // pmQuerierAddress (optional)
});

// 3) Get the ERC20 contract
const erc20 = polkamarkets.getERC20Contract({
  contractAddress: '0xf19609e96187cdaa34cffb96473fac567e547302' // erc20Address
});

// 4) (Optional) Log in (not strictly required if using private key, but included for completeness)
await polkamarkets.login();

// 5) Grab current user address
const userAddress = await polkamarkets.getAddress();
console.log('User address:', userAddress);

// 6) Check allowance for the pm contract
const neededAmount = '100000000'; 
const spender = '0x4f4988A910f8aE9B3214149A8eA1F2E4e3Cd93CC';

const approved = await erc20.isApproved({
  address: userAddress,
  spenderAddress: spender,
  amount: neededAmount
});

if (!approved) {
  console.log('Not enough allowance; approving now...');
  await erc20.approve({
    address: userAddress,
    amount: neededAmount,
    spenderAddress: spender
  });
  console.log('Approval successful!');
} else {
  console.log('Sufficient allowance already exists.');
}

// 7) Buy some outcome shares of a marketId
const marketId = 123; // the market id you want to purchase shares
const outcomeId = 0; // the market id you want to purchase shares
const value = 10; // the amount (in human format, it is converted to the correct decimals in the function)
const minOutcomeSharesToBuy = await pm.calcBuyAmount({
	marketId,
	outcomeId,
	value
});

await pm.buy({
  marketId,
  outcomeId,
  value,
  minOutcomeSharesToBuy
});
console.log('Bought outcome shares!');
const portfolio = await pm.getPortfolio({ user: userAddress });
console.log(portfolio);

// 9) (Later) Claim winnings (assumes market eventually resolves in your favor)
// ...
// await pm.claimWinnings(marketId);
// console.log('Winnings claimed!');
```

### Flow

1. **Initialization**: We pass a `web3Provider` (`api.mainnet.abs.xyz`) and a random `web3PrivateKey` for direct signing, plus `isSocialLogin: false` to skip the wallet UI.
2. **Contracts**:
    - **`pm`** is our Prediction Market V3 instance.
    - **`erc20`** is the token contract used for buying shares or adding liquidity.
3. **Login**: If you prefer a standard wallet approach (Metamask, etc.), remove `web3PrivateKey` and set `isSocialLogin: true`; calling `await polkamarkets.login()` triggers the wallet flow.
4. **Approval**: We check if the user has at least `neededAmount` allowance for the PM contract, then approve if needed.
5. **Buy**: We purchase outcome 0 with `'50000000'` units of the token. Adjust to match your token’s decimals.
6. **Claim**: Eventually, after resolution, you might call `pm.claimWinnings(marketId)` if you hold the winning outcome.
