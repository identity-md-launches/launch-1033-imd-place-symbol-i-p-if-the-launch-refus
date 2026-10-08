import {
  Contract,
  FetchRequest,
  Interface,
  JsonRpcProvider,
  getBytes,
  isAddress,
  keccak256,
  toQuantity,
  toUtf8Bytes,
} from "ethers";
import config from "./launch-config.json";
import abis from "./abi.json";
import { quoteOverrides, same } from "./core";
export { config, abis };
function provider(url: string) {
  const request = new FetchRequest(url);
  request.timeout = 20000;
  return new JsonRpcProvider(request, undefined, {
    cacheTimeout: -1,
    batchMaxCount: 20,
  });
}
export let rpc = provider(config.rpcUrls[0]);
const alternate = provider(config.rpcUrls[1]);
export const hook = new Contract(config.contracts.hook, abis.PlaceHook, rpc);
export const canvas = new Contract(config.contracts.canvas, abis.Canvas, rpc);
export const seasons = new Contract(
  config.contracts.seasons,
  abis.Seasons,
  rpc,
);
export const router = new Contract(
  config.contracts.router,
  abis.PlaceRouter,
  rpc,
);
export const imd = new Contract(config.contracts.imd, abis.PlaceToken, rpc);
export const token = new Contract(config.contracts.token, abis.PlaceToken, rpc);
export const contracts = [hook, canvas, seasons, router, imd, token];
export const interfaces = [
  ...contracts.map((c) => c.interface),
  new Interface(abis.CustomRevert),
];
export type Pixel = {
  owner: string;
  colour: bigint;
  paints: bigint;
  windowStart: bigint;
  rank: bigint;
};
export async function verifyDeployment() {
  if ((await rpc.getNetwork()).chainId !== BigInt(config.chainId))
    throw Error("RPC chain mismatch. Transactions are disabled.");
  const canonical = (x: unknown): unknown =>
    Array.isArray(x)
      ? x.map(canonical)
      : x && typeof x === "object"
        ? Object.fromEntries(
            Object.entries(x)
              .sort(([a], [b]) => a.localeCompare(b))
              .map(([k, v]) => [k, canonical(v)]),
          )
        : x;
  for (const name of ["PlaceToken", "PlaceHook"] as const) {
    if (
      keccak256(toUtf8Bytes(JSON.stringify(canonical(abis[name])))).slice(2) !==
      config.abiHashes[name]
    )
      throw Error("ABI integrity check failed. Transactions are disabled.");
  }
  const code = await Promise.all(
    Object.values(config.contracts).map((address) => rpc.getCode(address)),
  );
  for (const [i, name] of Object.keys(config.contracts).entries()) {
    if (
      code[i] === "0x" ||
      keccak256(code[i]) !==
        config.codeHashes[name as keyof typeof config.codeHashes]
    )
      throw Error(
        "Launch bytecode verification failed. Transactions are disabled.",
      );
  }
  for (const name of [
    "canvas",
    "router",
    "token",
    "imd",
    "poolManager",
  ] as const) {
    if (!same(await hook[name](), config.contracts[name]))
      throw Error("Launch contract relationship mismatch.");
  }
  if (
    !same(await canvas.seasons(), config.contracts.seasons) ||
    !same(await canvas.hook(), config.contracts.hook) ||
    !same(await canvas.imd(), config.contracts.imd) ||
    !same(await router.hook(), config.contracts.hook) ||
    !same(await router.manager(), config.contracts.poolManager) ||
    !same(await seasons.canvas(), config.contracts.canvas)
  )
    throw Error("Child contract relationship mismatch.");
  if (!(await hook.initialized()))
    throw Error("The trading pool has not been initialized.");
  const key = await hook.getPoolKey();
  if (
    !same(key.hooks, config.contracts.hook) ||
    Number(key.fee) !== 12500 ||
    Number(key.tickSpacing) !== 60 ||
    ![key.currency0, key.currency1].every(
      (a) => same(a, config.contracts.imd) || same(a, config.contracts.token),
    )
  )
    throw Error("Unexpected pool configuration.");
  return key;
}
export async function readOwners(season: bigint): Promise<Pixel[]> {
  const all: Pixel[] = [];
  for (let start = 0; start < 4096; start += 1024) {
    const pages = await Promise.all(
      [0, 256, 512, 768].map((offset) =>
        canvas.pixelPage(season, start + offset, 256),
      ),
    );
    for (const page of pages) all.push(...page);
  }
  return all;
}
// Only eth_call receives these temporary funding/approval overrides. No storage is changed on chain.
// Verify both slot locations through the token's own public getters before trusting a quote.
export async function simulateSwap(
  buy: boolean,
  amount: bigint,
  limit: bigint,
  deadline: number,
  caller = config.contracts.router,
) {
  const input = buy ? imd : token,
    slots = buy ? config.storage.imd : config.storage.token;
  const overrides = quoteOverrides(
    String(input.target),
    caller,
    config.contracts.router,
    amount,
    slots,
  );
  const test = async (method: string, args: unknown[]) =>
    input.interface.decodeFunctionResult(
      method,
      await rpc.send("eth_call", [
        {
          to: input.target,
          data: input.interface.encodeFunctionData(method, args),
        },
        "latest",
        overrides,
      ]),
    )[0];
  if (
    (await test("balanceOf", [caller])) !== amount ||
    (await test("allowance", [caller, config.contracts.router])) !== amount
  )
    throw Error(
      "Quote simulation is unavailable. Token storage verification failed.",
    );
  const data = router.interface.encodeFunctionData("swap", [
    buy,
    true,
    amount,
    1n,
    limit,
    deadline,
  ]);
  const result = await rpc.send("eth_call", [
    { to: router.target, from: caller, data },
    "latest",
    overrides,
  ]);
  return router.interface.decodeFunctionResult("swap", result) as unknown as [
    bigint,
    bigint,
  ];
}
export type History = {
  to: number;
  hash: string;
  credited: string;
  claimed: Record<string, string>;
  artists: string[];
};
const cacheKey = "imd-place-1033-history-v1";
let history: History = {
  to: config.launchBlock - 1,
  hash: "",
  credited: "0",
  claimed: {},
  artists: [],
};
try {
  const cached = JSON.parse(localStorage.getItem(cacheKey) || "null");
  if (
    Number.isSafeInteger(cached?.to) &&
    cached.to >= history.to &&
    typeof cached.hash === "string" &&
    /^0x[0-9a-f]{64}$/i.test(cached.hash) &&
    typeof cached.credited === "string" &&
    /^\d+$/.test(cached.credited) &&
    cached.claimed &&
    typeof cached.claimed === "object" &&
    Object.entries(cached.claimed).every(
      ([a, v]) => isAddress(a) && typeof v === "string" && /^\d+$/.test(v),
    ) &&
    Array.isArray(cached.artists) &&
    cached.artists.every((a: unknown) => typeof a === "string" && isAddress(a))
  )
    history = cached;
} catch {
  /* Storage is optional. */
}
let logsRpc = rpc;
const topics = [
  canvas.interface.getEvent("PaintCredited")!.topicHash,
  canvas.interface.getEvent("Painted")!.topicHash,
  canvas.interface.getEvent("Claimed")!.topicHash,
  seasons.interface.getEvent("Claimed")!.topicHash,
];
export async function scanHistory(
  latest: number,
  progress: (message: string) => void,
): Promise<History> {
  // Twelve blocks of delay plus a checkpoint hash keep unconfirmed events out of lifetime totals.
  const target = latest - 12;
  if (history.hash) {
    const block = await logsRpc.getBlock(history.to);
    if (history.to > target || !block || block.hash !== history.hash) {
      history = {
        to: config.launchBlock - 1,
        hash: "",
        credited: "0",
        claimed: {},
        artists: [],
      };
    }
  }
  let range = 10000;
  while (history.to < target) {
    const end = Math.min(target, history.to + range),
      from = history.to + 1;
    progress(
      `Indexing events · ${Math.round(((end - config.launchBlock + 1) / Math.max(1, target - config.launchBlock + 1)) * 100)}%`,
    );
    let logs;
    try {
      logs = await logsRpc.getLogs({
        address: [config.contracts.canvas, config.contracts.seasons],
        topics: [topics],
        fromBlock: from,
        toBlock: end,
      });
    } catch (error) {
      if (logsRpc === rpc) {
        logsRpc = alternate;
        continue;
      }
      if (range > 128) {
        range = Math.floor(range / 2);
        continue;
      }
      throw error;
    }
    const next: History = {
      ...history,
      claimed: { ...history.claimed },
      artists: [...history.artists],
    };
    const artists = new Set(next.artists);
    for (const log of logs) {
      const iface = same(log.address, config.contracts.canvas)
        ? canvas.interface
        : seasons.interface;
      const e = iface.parseLog(log);
      if (!e) continue;
      if (e.name === "PaintCredited")
        next.credited = (BigInt(next.credited) + e.args.drops).toString();
      if (e.name === "Painted") artists.add(e.args.artist.toLowerCase());
      if (e.name === "Claimed") {
        const a = e.args.artist.toLowerCase();
        artists.add(a);
        next.claimed[a] = (
          BigInt(next.claimed[a] || 0) + e.args.amount
        ).toString();
      }
    }
    const block = await logsRpc.getBlock(end);
    if (!block?.hash)
      throw Error(
        "Could not verify the event checkpoint. Retry the history scan.",
      );
    next.to = end;
    next.hash = block.hash;
    next.artists = [...artists];
    history = next;
    try {
      localStorage.setItem(cacheKey, JSON.stringify(history));
    } catch {
      /* Continue without persistent cache. */
    }
  }
  return history;
}
export const nowBlock = async () => {
  const b = await rpc.getBlock("latest");
  if (!b) throw Error("Latest block is unavailable.");
  return b;
};
export const unpack = (hex: string) => getBytes(hex);
export const blockTag = (n: number) => toQuantity(n);
