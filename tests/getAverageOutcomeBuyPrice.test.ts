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
    events: [
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 100, value: 500 }, // local avg = 5
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 50, value: 300 }, // local avg = 6, new avg formula = (5 * 100 + 6 * 50) / 150 = 5.33
    ],
    expected: 5.33,
  },

  {
    events: [
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 100, value: 500 }, // local avg = 5
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 50, value: 200 }, // sell, avg = 5
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 50, value: 500 }, // local avg = 10, new avg formula = (5 * 50 + 10 * 50) / 100 = 7.5
    ],
    expected: 7.5,
  },

  {
    events: [
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 50, value: 200 }, // sell, avg = 0
    ],
    expected: 0,
  },

  {
    events: [
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 200, value: 800 }, // local avg = 4, avg = 4
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 50, value: 200 }, // sell, avg = 4
      { action: "Buy", marketId: 1, outcomeId: 1, shares: 100, value: 600 }, // local avg = 6, new avg formula = (4 * 150 + 6 * 100) / 250 = 4.8
      { action: "Sell", marketId: 1, outcomeId: 1, shares: 100, value: 400 }, // sell, avg = 4.8
    ],
    expected: 4.8,
  },

  {
    events: [],
    expected: 0,
  },
];

// 2. Покупки и частичная продажа
describe("getAverageOutcomeBuyPriceV1", () => {
  testDatasets.forEach((dataset, index) => {
    it(`should return correct average for dataset ${index + 1}`, () => {
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
    it(`should return correct average for dataset ${index + 1}`, () => {
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
    it(`should return the same average for dataset ${index + 1}`, () => {
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
