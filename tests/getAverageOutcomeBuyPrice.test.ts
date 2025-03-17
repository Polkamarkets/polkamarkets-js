import { expect } from "chai";
import "mocha";

/**
 * The old implementation of the function
 */
function getAverageOutcomeBuyPriceV1({ events, marketId, outcomeId }) {
  // filtering by marketId + outcomeId + buy action
  events = events.filter((event) => {
    return (
      event.action === "Buy" &&
      event.marketId === marketId &&
      event.outcomeId === outcomeId
    );
  });

  if (events.length === 0) return 0;

  const totalShares = events
    .map((item) => item.shares)
    .reduce((prev, next) => prev + next);
  const totalAmount = events
    .map((item) => item.value)
    .reduce((prev, next) => prev + next);

  return totalAmount / totalShares;
}

/**
 * The new implementation of the function
 * The key difference is that we calculate the proportion of the shares that were sold
 * and adjust the totalShares and totalAmount accordingly
 */
function getAverageOutcomeBuyPriceV2({ events, marketId, outcomeId }) {
  let totalShares = 0;
  let totalAmount = 0;

  events.forEach((event) => {
    if (event.marketId === marketId && event.outcomeId === outcomeId) {
      if (event.action === "Buy") {
        totalShares += event.shares;
        totalAmount += event.value;
      } else if (event.action === "Sell") {
        const proportion = event.shares / totalShares;
        totalShares -= event.shares;
        totalAmount *= 1 - proportion;
      }
    }
  });

  return totalShares === totalShares && totalAmount
    ? totalAmount / totalShares
    : 0;
}

const testDatasets = [
  {
    name: "Double buy",
    events: [
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 500, value: 100 }, // local avg = 0.2
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 300, value: 50 }, // local avg = 0.167, new avg formula = (0.2 * 500 + 0.167 * 300) / 800 = 0.1875
    ],
    expected: 0.1875,
  },

  {
    name: "Buy, partial sell, buy",
    events: [
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 500, value: 100 }, // local avg = 0.2
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 200, value: 40 }, // sell, avg = 0.2
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 500, value: 50 }, // local avg = 0.1, new avg formula = (0.2 * 300 + 0.1 * 500) / 800 = 0.1375
    ],
    expected: 0.1375,
  },

  {
    name: "Simple sell",
    events: [
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 200, value: 40 }, // sell, avg = 0
    ],
    expected: 0,
  },

  {
    name: "Buy, sell, buy, sell",
    events: [
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 800, value: 200 }, // local avg = 0.25, avg = 0.25
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 200, value: 50 }, // sell, avg = 0.25
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 600, value: 100 }, // local avg = 0.167, new avg formula = (0.25 * 600 + 0.167 * 600) / 1200 = 0.2083
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 400, value: 100 }, // sell, avg = 0.2083
    ],
    expected: 0.2083,
  },

  {
    name: "Buy, sell everything, buy",
    events: [
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 500, value: 100 }, // local avg = 0.2
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 500, value: 100 }, // sell everything, avg = 0
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 300, value: 50 }, // local avg = 0.167, avg = 0.167
    ],
    expected: 0.167,
  },

  {
    name: "Complex realworld example",
    events: [
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 1421.16, value: 1000 },
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 1151.19, value: 1000 },
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 1077.79, value: 1000 },
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 3650.14, value: 581.154 },
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 4129.38, value: 800 },
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 4129.37, value: 799.999 },
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 1220.82, value: 1000 },
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 1190.56, value: 1000 },
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 1091.43, value: 1000 },
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 3502.82, value: 586.356 },
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 13.8745, value: 10 },
    ],
    expected: 0.72,
  },

  {
    name: "No events",
    events: [],
    expected: 0,
  },
];

// 2. Покупки и частичная продажа
describe("getAverageOutcomeBuyPriceV1", () => {
  testDatasets.forEach((dataset, index) => {
    it(`should return correct average for dataset #${index + 1} "${
      dataset.name
    }"`, () => {
      const result = getAverageOutcomeBuyPriceV1({
        events: dataset.events,
        marketId: 1,
        outcomeId: 1,
      });
      expect(result).to.be.closeTo(dataset.expected, 0.01);
    });
  });
});

describe("getAverageOutcomeBuyPriceV2", () => {
  testDatasets.forEach((dataset, index) => {
    it(`should return correct average for dataset #${index + 1} "${
      dataset.name
    }"`, () => {
      const result = getAverageOutcomeBuyPriceV2({
        events: dataset.events,
        marketId: 1,
        outcomeId: 1,
      });
      expect(result).to.be.closeTo(dataset.expected, 0.01);
    });
  });
});

describe("Comparison of V1 and V2", () => {
  testDatasets.forEach((dataset, index) => {
    it(`should return the same average for dataset #${index + 1} "${
      dataset.name
    }"`, () => {
      const resultV1 = getAverageOutcomeBuyPriceV1({
        events: dataset.events,
        marketId: 1,
        outcomeId: 1,
      });
      const resultV2 = getAverageOutcomeBuyPriceV2({
        events: dataset.events,
        marketId: 1,
        outcomeId: 1,
      });
      expect(resultV1).to.be.closeTo(resultV2, 0.01);
    });
  });
});
