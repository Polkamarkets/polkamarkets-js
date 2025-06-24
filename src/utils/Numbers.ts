import moment from "moment";

// Extend Number prototype
declare global {
  interface Number {
    noExponents(): string;
  }
}

Number.prototype.noExponents = function (): string {
  const data = String(this).split(/[eE]/);
  if (data.length === 1) return data[0];

  let z = "";
  const sign = (this as number) < 0 ? "-" : "";
  const str = data[0].replace(".", "");
  let mag = Number(data[1]) + 1;

  if (mag < 0) {
    z = sign + "0.";
    while (mag++) z += "0";
    return z + str.replace(/^\-/, "");
  }
  mag -= str.length;
  while (mag--) z += "0";
  return str + z;
};

interface DateInput {
  day: number;
  hour: number;
  year: number;
}

class NumbersUtil {
  constructor() {}

  fromDayMonthYear(date: DateInput): string {
    const mom = moment().dayOfYear(date.day);
    mom.set("hour", date.hour);
    mom.set("year", date.year);
    return mom.format("ddd, hA");
  }

  fromHex(hex: string | number): string {
    return hex.toString();
  }

  toFloat(number: number | string): number {
    return parseFloat(parseFloat(number.toString()).toFixed(2));
  }

  timeToSmartContractTime(time: Date | string | number): number {
    return parseInt((new Date(time).getTime() / 1000).toString());
  }

  toDate(date: DateInput): number {
    const mom = moment().dayOfYear(date.day);
    mom.set("hour", date.hour);
    mom.set("year", date.year);
    return mom.unix();
  }

  toSmartContractDecimals(value: number | string, decimals: number): string {
    const numberWithNoExponents = new Number(
      (Number(value) * 10 ** decimals).toFixed(0),
    ).noExponents();
    return numberWithNoExponents;
  }

  fromBigNumberToInteger(value: number, decimals: number = 18): number {
    return Math.round((value / Math.pow(10, decimals)) * 1000000000000000000);
  }

  fromDecimals(value: number, decimals: number): string {
    return Number(
      parseFloat((value / 10 ** decimals).toString()).toPrecision(decimals),
    ).noExponents();
  }

  fromDecimalsNumber(value: number, decimals: number): number {
    const number = Number(
      parseFloat((value / 10 ** decimals).toString()).toPrecision(decimals),
    ).noExponents();
    return Number(number);
  }

  fromExponential(x: number): string {
    if (Math.abs(x) < 1.0) {
      const e = parseInt(x.toString().split("e-")[1]);
      if (e) {
        x *= Math.pow(10, e - 1);
        x = Number("0." + new Array(e).join("0") + x.toString().substring(2));
      }
    } else {
      const e = parseInt(x.toString().split("+")[1]);
      if (e > 20) {
        const newE = e - 20;
        x /= Math.pow(10, newE);
        x = Number(x.toString() + new Array(newE + 1).join("0"));
      }
    }
    return x.toString();
  }

  nullHash(): string {
    return "0x0000000000000000000000000000000000000000000000000000000000000000";
  }
}

const Numbers = new NumbersUtil();

export default Numbers;
