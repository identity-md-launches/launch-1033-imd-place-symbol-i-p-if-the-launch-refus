import {
  AbiCoder,
  Interface,
  formatUnits,
  keccak256,
  parseUnits,
  toBeHex,
} from "ethers";
export const names = [
  "Ink",
  "White",
  "Silver",
  "Slate",
  "Red",
  "Orange",
  "Yellow",
  "Lime",
  "Teal",
  "Cyan",
  "Blue",
  "Indigo",
  "Violet",
  "Pink",
  "Brown",
  "Peach",
];
export const same = (a?: string, b?: string) =>
  !!a && !!b && a.toLowerCase() === b.toLowerCase();
export const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);
export function format(value: bigint, places = 5): string {
  const [whole, fraction = ""] = formatUnits(value, 18).split(".");
  if (value > 0n && value < 10n ** BigInt(18 - places))
    return "<0." + "0".repeat(places - 1) + "1";
  const f = fraction.slice(0, places).replace(/0+$/, "");
  return whole + (f ? "." + f : "");
}
export function amountValue(value: string): bigint {
  if (!/^(?:\d+)(?:\.\d{0,18})?$/.test(value.trim()))
    throw Error("Enter a positive amount with at most 18 decimal places.");
  const amount = parseUnits(value.trim(), 18);
  if (amount <= 0n) throw Error("Enter an amount greater than zero.");
  return amount;
}
export function slippageMinimum(received: bigint, value: string): bigint {
  if (!/^\d+(\.\d{1,2})?$/.test(value))
    throw Error(
      "Use slippage between 0.1% and 10%, with at most two decimal places.",
    );
  const bps = Number(value) * 100;
  if (bps < 10 || bps > 1000) throw Error("Use slippage between 0.1% and 10%.");
  const min = (received * BigInt(10000 - Math.round(bps))) / 10000n;
  if (min < 1n)
    throw Error(
      "This amount is too small. Increase the amount and quote again.",
    );
  return min;
}
export function priceLimit(buy: boolean, imd0: boolean): bigint {
  return buy === imd0
    ? 4295128740n
    : 1461446703485210103287273052203988822378723970341n;
}
export function togglePixel(
  selection: Map<number, number>,
  id: number,
  colour: number,
): void {
  if (!Number.isInteger(id) || id < 0 || id > 4095 || colour < 0 || colour > 15)
    throw Error("Choose coordinates from 0 to 63.");
  if (selection.get(id) === colour) selection.delete(id);
  else {
    if (selection.size >= 50 && !selection.has(id))
      throw Error(
        "You can paint 50 pixels at once. Clear one selection to add another.",
      );
    selection.set(id, colour);
  }
}
export function quoteOverrides(
  token: string,
  caller: string,
  router: string,
  amount: bigint,
  slots: { balance: number; allowance: number },
) {
  const map = (address: string, slot: number | bigint) =>
    keccak256(
      AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256"],
        [address, slot],
      ),
    );
  return {
    [token]: {
      stateDiff: {
        [map(caller, slots.balance)]: toBeHex(amount, 32),
        [map(router, BigInt(map(caller, slots.allowance)))]: toBeHex(
          amount,
          32,
        ),
      },
    },
  };
}
export const errorMessages: Record<string, string> = {
  InsufficientPaint:
    "Not enough paint. Buy i/p to earn drops, or select fewer pixels.",
  BudgetExceeded:
    "A selected pixel became more expensive. Refresh the paint cost and review again.",
  SeasonNotReady:
    "Painting is closed when the season ends. Refresh the canvas and check the season timer.",
  PreviousAuctionPending:
    "Settle the previous auction before ending this season.",
  InvalidBatch: "Select between 1 and 50 distinct pixels.",
  InvalidPixel: "Choose coordinates from 0 to 63.",
  Slippage:
    "The price moved past your minimum. Get a new quote before trying again.",
  InvalidSwap: "This quote expired or the amount is invalid. Get a new quote.",
  AuctionClosed: "This auction is closed. Refresh to see the result.",
  BidTooLow:
    "Another bid changed the minimum. Refresh the auction and bid again.",
  NotReady:
    "The season or auction is not ready. Refresh and check its deadline.",
  AlreadyClaimed:
    "These season pixels have already been claimed. Refresh the collection.",
  ERC20InsufficientBalance:
    "Not enough tokens for this transaction. Check your balance.",
  ERC20InsufficientAllowance:
    "Token approval is required. Approve the displayed amount first.",
  PartialFill:
    "There is not enough liquidity for the full trade. Try a smaller amount.",
};
export function readableError(
  error: unknown,
  interfaces: Interface[] = [],
  depth = 0,
): string {
  const e = error as {
    code?: number | string;
    revert?: { name: string };
    data?: string;
    info?: { error?: { data?: string; message?: string } };
    error?: { data?: string };
    shortMessage?: string;
    message?: string;
  };
  if (e.code === 4001 || e.code === "ACTION_REJECTED")
    return "Request declined in your wallet. Nothing was submitted by this action.";
  let name = e.revert?.name;
  const data = e.data || e.info?.error?.data || e.error?.data;
  if (typeof data === "string")
    for (const iface of interfaces) {
      try {
        const parsed = iface.parseError(data);
        if (parsed) {
          if (parsed.name === "WrappedError" && depth < 4)
            return readableError(
              { data: parsed.args.reason },
              interfaces,
              depth + 1,
            );
          name = parsed.name;
          break;
        }
      } catch {
        /* Try next ABI. */
      }
    }
  if (name && errorMessages[name]) return errorMessages[name];
  const message =
    e.shortMessage ||
    e.info?.error?.message ||
    e.message ||
    "Unable to complete this request. Please try again.";
  return message.length > 250
    ? "Unable to complete this request. Refresh and check your wallet and RPC connection."
    : message;
}
export function seasonShare(
  payout: bigint,
  occupied: bigint,
  ranks: bigint[],
): bigint {
  if (!occupied) return 0n;
  return ranks.reduce(
    (sum, rank) =>
      sum + payout / occupied + (rank <= payout % occupied ? 1n : 0n),
    0n,
  );
}
