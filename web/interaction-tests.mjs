// These isolated fixtures never forward wallet transactions to a network.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { resolve, extname } from "node:path";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { createServer } from "node:http";
const root = fileURLToPath(new URL("../", import.meta.url));
const home = process.env.IMD_TOOLCHAIN || "/tmp/imd-place-toolchain";
process.env.PLAYWRIGHT_BROWSERS_PATH ||= "/tmp/imd-place-browsers";
const require = createRequire(resolve(home, "package.json"));
const { chromium, expect } = require("@playwright/test");
const { ethers: e } = require("ethers");
const { build } = require("esbuild");
const json = async (p) => JSON.parse(await readFile(resolve(root, p), "utf8"));
const config = await json("site/launch-config.json"),
  abis = await json("site/abi.json"),
  fixture = await json("web/fixtures/chain.json");
const c = config.contracts,
  account = c.token,
  other = c.hook,
  interfaces = Object.fromEntries(
    Object.entries(abis).map(([n, a]) => [n, new e.Interface(a)]),
  );
const report = {
  checkedAt: new Date().toISOString(),
  fixtureChecks: [],
  liveChecks: [],
  accessibility: [],
  consoleErrors: [],
  limitations: [
    "Wallet approvals and submissions use an isolated EIP-1193 fixture that rejects submission; no live transaction was sent.",
    "Desktop Chromium automation does not certify native mobile wallet apps or screen-reader behavior.",
  ],
};
const pass = (label) => {
  report.fixtureChecks.push(label);
  console.log("PASS", label);
};
await mkdir("/tmp/imd-place-tests", { recursive: true });
await build({
  entryPoints: [resolve(root, "site/core.ts")],
  outfile: "/tmp/imd-place-tests/core.mjs",
  bundle: true,
  platform: "node",
  format: "esm",
  alias: { ethers: resolve(home, "node_modules/ethers/lib.esm/index.js") },
  logLevel: "silent",
});
const core = await import(pathToFileURL("/tmp/imd-place-tests/core.mjs"));
assert.equal(core.amountValue("0.000000000000000001"), 1n);
for (const v of ["0", "-1", "1e18", "NaN", "0.0000000000000000001"])
  assert.throws(() => core.amountValue(v));
assert.equal(core.slippageMinimum(10000n, "1"), 9900n);
assert.throws(() => core.slippageMinimum(10000n, "11"));
assert.throws(() => core.slippageMinimum(1n, "1"));
const selected = new Map();
for (let i = 0; i < 50; i++) core.togglePixel(selected, i, 4);
assert.throws(() => core.togglePixel(selected, 50, 4));
core.togglePixel(selected, 0, 5);
assert.equal(selected.size, 50);
core.togglePixel(selected, 0, 5);
assert.equal(selected.size, 49);
assert.equal(core.seasonShare(10n, 3n, [1n, 2n, 3n]), 10n);
assert.equal(
  core.readableError({ data: "0x8e89355b" }, [interfaces.Canvas]),
  "Not enough paint. Buy i/p to earn drops, or select fewer pixels.",
);
assert.equal(
  core.readableError(
    {
      data: interfaces.CustomRevert.encodeErrorResult("WrappedError", [
        c.hook,
        "0xb47b2fb1",
        interfaces.PlaceHook.encodeErrorResult("PartialFill", []),
        "0xa9e35b2f",
      ]),
    },
    Object.values(interfaces),
  ),
  core.errorMessages.PartialFill,
);
pass(
  "Amount precision, slippage bounds, distinct 50-pixel limit, season rounding and real InsufficientPaint selector",
);
const server = createServer(async (req, res) => {
  try {
    const path = decodeURIComponent(new URL(req.url, "http://local").pathname);
    if (!path.startsWith("/place/")) {
      res.writeHead(404);
      res.end();
      return;
    }
    const relative = path.slice("/place/".length) || "index.html";
    if (relative.includes("..")) throw Error();
    const file = await readFile(resolve(root, "dist", relative));
    const mime =
      {
        ".html": "text/html",
        ".js": "text/javascript",
        ".css": "text/css",
        ".svg": "image/svg+xml",
        ".ttf": "font/ttf",
        ".json": "application/json",
        ".txt": "text/plain",
      }[extname(relative)] || "application/octet-stream";
    res.writeHead(200, { "Content-Type": mime });
    res.end(file);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${server.address().port}/place/`;
let browser;
try {
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
  });
  const page = await context.newPage();
  page.on("pageerror", (err) => report.consoleErrors.push(err.message));
  page.on("console", (msg) => {
    if (msg.type() === "error") report.consoleErrors.push(msg.text());
  });
  const state = {
    time: Number(BigInt(fixture.block.timestamp)),
    block: Number(BigInt(fixture.block.number)),
    season: 2n,
    start: 0,
    finalized: false,
    auctionEnd: 0,
    paintError: false,
    drops: 200n,
    allowance: 0n,
  };
  state.start = state.time - 300;
  state.auctionEnd = state.time + 600;
  const eventLogs = [];
  function event(name, event, args, address, index) {
    const encoded = interfaces[name].encodeEventLog(
      interfaces[name].getEvent(event),
      args,
    );
    return {
      address,
      topics: encoded.topics,
      data: encoded.data,
      blockNumber: e.toQuantity(config.launchBlock + 10),
      blockHash: fixture.block.hash,
      transactionHash: e.id("fixture event " + index),
      transactionIndex: "0x0",
      logIndex: e.toQuantity(index),
      removed: false,
    };
  }
  eventLogs.push(
    event("Canvas", "PaintCredited", [account, 20n], c.canvas, 0),
    event("Canvas", "Painted", [2n, 0, account, 4, 1n], c.canvas, 1),
    event("Canvas", "Painted", [2n, 1, other, 7, 1n], c.canvas, 2),
    event("Canvas", "Claimed", [account, e.parseEther("1")], c.canvas, 3),
  );
  const pixel = (id) =>
    id < 2
      ? [
          id === 0 ? account : other,
          id === 0 ? 4 : 7,
          3,
          state.time - 100,
          id + 1,
        ]
      : [e.ZeroAddress, 0, 0, 0, 0];
  const nft =
    "data:application/json;base64," +
    Buffer.from(
      JSON.stringify({
        name: "Fixture season 1",
        image:
          "data:image/svg+xml;base64," +
          Buffer.from(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path fill="#181425" d="M0 0h64v64H0z"/><path fill="#ff0044" d="M0 0h16v16H0z"/><path fill="#63c74d" d="M16 0h16v16H16z"/></svg>',
          ).toString("base64"),
      }),
    ).toString("base64");
  const handle = async (req) => {
    const params = req.params || [],
      method = req.method;
    let result;
    if (method === "eth_chainId") result = e.toQuantity(config.chainId);
    else if (method === "eth_blockNumber") result = e.toQuantity(state.block);
    else if (method === "eth_getBlockByNumber")
      result = {
        ...fixture.block,
        number: params[0] === "latest" ? e.toQuantity(state.block) : params[0],
        timestamp: e.toQuantity(state.time),
        transactions: [],
      };
    else if (method === "eth_getCode")
      result = fixture.codes[params[0].toLowerCase()];
    else if (method === "eth_getLogs") {
      const f = params[0];
      result = eventLogs.filter(
        (l) =>
          BigInt(l.blockNumber) >= BigInt(f.fromBlock) &&
          BigInt(l.blockNumber) <= BigInt(f.toBlock),
      );
    } else if (method === "eth_getTransactionCount") result = "0x0";
    else if (method === "eth_gasPrice" || method === "eth_maxPriorityFeePerGas")
      result = "0x3b9aca00";
    else if (method === "eth_estimateGas") result = "0x7a120";
    else if (method === "eth_call") {
      const tx = params[0],
        target = tx.to.toLowerCase(),
        name =
          target === c.hook.toLowerCase()
            ? "PlaceHook"
            : target === c.canvas.toLowerCase()
              ? "Canvas"
              : target === c.seasons.toLowerCase()
                ? "Seasons"
                : target === c.router.toLowerCase()
                  ? "PlaceRouter"
                  : "PlaceToken";
      const iface = interfaces[name],
        parsed = iface.parseTransaction({ data: tx.data }),
        fn = parsed.name,
        args = parsed.args;
      let values;
      if (
        fn in c &&
        [
          "canvas",
          "router",
          "token",
          "imd",
          "poolManager",
          "seasons",
          "hook",
        ].includes(fn)
      )
        values = [c[fn]];
      else if (fn === "manager") values = [c.poolManager];
      else if (fn === "initialized") values = [true];
      else if (fn === "getPoolKey")
        values = [[c.imd, c.token, 12500, 60, c.hook]];
      else if (fn === "getPalette")
        values = [
          [
            "181425",
            "ffffff",
            "c0cbdc",
            "5a6988",
            "ff0044",
            "ff8426",
            "ffd635",
            "63c74d",
            "009e8f",
            "22d3ee",
            "0099db",
            "3e52f5",
            "8b46ff",
            "f472b6",
            "8f563b",
            "ffccaa",
          ].map((x) => parseInt(x, 16)),
        ];
      else if (fn === "launchTime") values = [state.time - 200];
      else if (fn === "dropUnit") values = [e.parseEther("0.05")];
      else if (fn === "feeBps") values = [3133];
      else if (fn === "currentSeason") values = [state.season];
      else if (fn === "seasonStart") values = [state.start];
      else if (fn === "coloursOf") {
        const bytes = new Uint8Array(4096).fill(255);
        bytes[0] = 4;
        bytes[1] = 7;
        values = [e.hexlify(bytes)];
      } else if (fn === "stats") values = [2, 2, 12, account, 8];
      else if (fn === "pixelPage")
        values = [
          Array.from({ length: Number(args[2]) }, (_, i) =>
            pixel(Number(args[1]) + i),
          ),
        ];
      else if (fn === "pixels") values = pixel(Number(args[1]));
      else if (fn === "price") values = [Number(args[0]) < 2 ? 8 : 1];
      else if (fn === "drops") values = [state.drops];
      else if (fn === "claimable") values = [e.parseEther("0.5")];
      else if (fn === "pendingRefunds") values = [e.parseEther("2")];
      else if (fn === "totalPaid") values = [e.parseEther("1")];
      else if (fn === "seasonPot") values = [e.parseEther("2")];
      else if (fn === "balanceOf" || fn === "allowance") {
        const diff =
          params[2]?.[target]?.stateDiff || params[2]?.[tx.to]?.stateDiff;
        if (diff) values = [BigInt(Object.values(diff)[0])];
        else
          values = [fn === "balanceOf" ? e.parseEther("100") : state.allowance];
      } else if (fn === "swap")
        values = [args[2], args[0] ? args[2] * 10n : args[2] / 10n];
      else if (fn === "auctions")
        values = [
          state.auctionEnd,
          2,
          2,
          12,
          account,
          other,
          state.finalized,
          e.parseEther("5"),
          e.parseEther("2"),
          state.finalized ? e.parseEther("7") : 0,
          0,
        ];
      else if (fn === "minimumBid") values = [e.parseEther("5.25")];
      else if (fn === "tokenURI") values = [nft];
      else if (fn === "rolloverResolved") values = [true];
      else if (fn === "claimedBitmap") values = [0];
      else if (fn === "paintWithLimit" && state.paintError)
        return {
          jsonrpc: "2.0",
          id: req.id,
          error: { code: 3, message: "execution reverted", data: "0x8e89355b" },
        };
      else if (
        ["paintWithLimit", "paint", "endSeason", "bid", "finalize"].includes(fn)
      )
        values = [];
      else if (fn === "approve") values = [true];
      else if (fn === "claim" || fn === "withdrawRefund")
        values = [e.parseEther("0.5")];
      else throw Error("Unhandled fixture call " + name + "." + fn);
      result = iface.encodeFunctionResult(fn, values);
    } else throw Error("Unhandled fixture RPC " + method);
    return { jsonrpc: "2.0", id: req.id, result };
  };
  await context.route(
    /https:\/\/(robinhood-rpc\.publicnode\.com|rpc\.mainnet\.chain\.robinhood\.com)\/?$/,
    async (route) => {
      try {
        const data = route.request().postDataJSON();
        const result = Array.isArray(data)
          ? await Promise.all(data.map(handle))
          : await handle(data);
        await route.fulfill({
          json: result,
          headers: { "access-control-allow-origin": "*" },
        });
      } catch (error) {
        console.error(error);
        await route.abort();
      }
    },
  );
  await context.addInitScript(
    ({ account, rpc }) => {
      const state = {
        chain: "0x1",
        added: false,
        calls: [],
        accounts: [account],
        listeners: {},
      };
      window.testWallet = state;
      const provider = {
        isRabby: true,
        request: async (req) => {
          state.calls.push(req);
          if (req.method === "eth_chainId") return state.chain;
          if (req.method === "wallet_switchEthereumChain") {
            if (!state.added) throw { code: 4902, message: "unknown chain" };
            state.chain = req.params[0].chainId;
            return null;
          }
          if (req.method === "wallet_addEthereumChain") {
            state.added = true;
            return null;
          }
          if (
            req.method === "eth_accounts" ||
            req.method === "eth_requestAccounts"
          )
            return state.accounts;
          if (req.method === "eth_sendTransaction")
            throw { code: 4001, message: "Fixture rejects every submission" };
          const response = await fetch(rpc, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              jsonrpc: "2.0",
              id: 777,
              method: req.method,
              params: req.params,
            }),
          });
          const data = await response.json();
          if (data.error) throw data.error;
          return data.result;
        },
        on: (name, fn) => {
          (state.listeners[name] ||= []).push(fn);
        },
        removeListener: (name, fn) => {
          state.listeners[name] = (state.listeners[name] || []).filter(
            (f) => f !== fn,
          );
        },
      };
      window.ethereum = provider;
      const announce = () => {
        dispatchEvent(
          new CustomEvent("eip6963:announceProvider", {
            detail: {
              info: { uuid: "fixture-rabby", name: "Rabby", rdns: "io.rabby" },
              provider,
            },
          }),
        );
        dispatchEvent(
          new CustomEvent("eip6963:announceProvider", {
            detail: {
              info: {
                uuid: "fixture-coinbase",
                name: "Coinbase Wallet",
                rdns: "com.coinbase.wallet",
              },
              provider: { ...provider },
            },
          }),
        );
      };
      addEventListener("eip6963:requestProvider", announce);
      announce();
    },
    { account, rpc: config.rpc },
  );
  await page.goto(url);
  await expect(page.locator("#connection")).toContainText("Live ·", {
    timeout: 30000,
  });
  await expect(page.locator("#history-status")).toContainText(
    "indexed through",
    { timeout: 30000 },
  );
  assert.equal(await page.locator("#palette button").count(), 16);
  await expect(page.locator("#gallery img")).toHaveAttribute(
    "src",
    /^data:image\/svg/,
  );
  await expect(page.locator("#fee-info")).toContainText("31.33%");
  pass(
    "Export works at /place/ with verified runtime code, 16 colours, launch decay and tokenURI artwork",
  );
  await page.locator("#canvas").click({ position: { x: 3, y: 3 } });
  await expect(page.locator("#pixel-info")).toContainText("3 paints");
  await expect(page.locator("#paint-cost")).toHaveText("8 drops");
  await expect(page.locator("#pixel-info a")).toHaveAttribute(
    "href",
    config.explorer + "/address/" + account,
  );
  pass(
    "Pixel inspection shows owner, 24-hour paint count and live repaint price",
  );
  await page.locator("#clear-selection").click();
  await page.locator("#canvas").focus();
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("Enter");
  await expect(page.locator("#selection-count")).toHaveText("1 pixel selected");
  await page.locator("#pan-mode").click();
  await page.locator("#canvas").focus();
  await page.keyboard.press("ArrowRight");
  assert.match(
    await page.locator("#canvas").getAttribute("style"),
    /translate\(-32px/,
  );
  await page.locator("#reset-view").click();
  await page.locator("#paint-mode").click();
  await page.locator("#zoom").focus();
  await page.keyboard.press("ArrowRight");
  await expect(page.locator("#zoom-label")).toHaveText("1.25×");
  await page.locator("#reset-view").click();
  pass("Keyboard selection, pointer selection, pan, zoom controls and reset");
  await page.locator("#clear-selection").click();
  await page.evaluate(() => {
    for (let x = 0; x < 51; x++) {
      document.querySelector("#coord-x").value = String(x);
      document.querySelector("#coord-y").value = "2";
      document.querySelector("#choose-coordinate").click();
    }
  });
  await expect(page.locator("#selection-count")).toHaveText(
    "50 pixels selected",
  );
  await expect(page.locator("#notice")).toContainText("50 pixels at once");
  await expect(page.locator("#paint-cost")).toHaveText("50 drops");
  pass("Browser rejects the 51st distinct pixel without changing the batch");
  await page.locator("#swap-amount").fill("-1");
  await page.locator("#quote").click();
  await expect(page.locator("#swap-amount")).toHaveAttribute(
    "aria-invalid",
    "true",
  );
  await expect(page.locator("#swap-error")).not.toBeEmpty();
  await page.locator("#swap-amount").fill("1");
  await page.locator("#slippage").fill("99");
  await page.locator("#quote").click();
  await expect(page.locator("#slippage")).toHaveAttribute(
    "aria-invalid",
    "true",
  );
  await page.locator("#slippage").fill("1");
  await page.locator("#quote").click();
  await expect(page.locator("#quote-info")).toContainText("Expected: 10 i/p");
  assert.equal(
    await page.evaluate(
      () =>
        testWallet.calls.filter((x) => x.method === "eth_sendTransaction")
          .length,
    ),
    0,
  );
  pass(
    "Positive amount/slippage validation and disconnected quote without approval or signing",
  );
  state.time += 121;
  await page.locator("#refresh").click();
  await expect(page.locator("#swap")).toBeDisabled();
  await expect(page.locator("#quote-info")).toContainText("expired");
  pass("Expired quotes cannot be submitted");
  await page.locator("#connect").click();
  await expect(
    page.getByRole("button", { name: "Connect Rabby", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Connect Coinbase Wallet", exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Connect Rabby", exact: true })
    .click();
  await expect(page.locator("#connect")).toContainText(core.short(account));
  assert.deepEqual(
    await page.evaluate(() =>
      testWallet.calls
        .filter((c) => c.method.startsWith("wallet_"))
        .map((c) => c.method),
    ),
    [
      "wallet_switchEthereumChain",
      "wallet_addEthereumChain",
      "wallet_switchEthereumChain",
    ],
  );
  await expect(page.locator("#drops")).toHaveText("200");
  pass(
    "EIP-6963 discovery, chain addition/switching and connected paint/token balances",
  );
  await page.locator("#submit-paint").click();
  await expect(page.locator("#review-content")).toContainText(
    "Maximum paint cost: 50 drops",
  );
  state.paintError = true;
  await page.locator("#confirm-review").click();
  await expect(page.locator("#review-error")).toHaveText(
    "Not enough paint. Buy i/p to earn drops, or select fewer pixels.",
  );
  assert.equal(
    await page.evaluate(
      () =>
        testWallet.calls.filter((x) => x.method === "eth_sendTransaction")
          .length,
    ),
    0,
  );
  state.paintError = false;
  await page.locator("#cancel-review").click();
  pass(
    "Bounded paint review and clear mainnet InsufficientPaint error before wallet submission",
  );
  await page.locator("#quote").click();
  await expect(page.locator("#swap")).toBeEnabled();
  await page.locator("#swap").click();
  await expect(page.locator("#review-content")).toContainText(
    "approve exactly 1.0 IMD",
  );
  await page.locator("#confirm-review").click();
  await expect(page.locator("#review-error")).toContainText("declined");
  let tx = await page.evaluate(
    () =>
      testWallet.calls.filter((x) => x.method === "eth_sendTransaction").at(-1)
        .params[0],
  );
  let decoded = interfaces.PlaceToken.parseTransaction({ data: tx.data });
  assert.equal(decoded.name, "approve");
  assert.equal(decoded.args[1], e.parseEther("1"));
  assert.equal(decoded.args[0].toLowerCase(), c.router.toLowerCase());
  await page.locator("#cancel-review").click();
  pass(
    "Buy approval is exact, targets PlaceRouter, and declined wallet requests remain recoverable",
  );
  await page.locator("#sell-mode").click();
  await expect(page.locator("#swap")).toBeDisabled();
  await page.locator("#quote").click();
  await expect(page.locator("#quote-info")).toContainText("Expected: 0.1 IMD");
  await page.locator("#swap").click();
  await expect(page.locator("#review-content")).toContainText(
    "Paint balance stays unchanged",
  );
  state.allowance = e.parseEther("100");
  await page.locator("#confirm-review").click();
  await expect(page.locator("#review-error")).toContainText("declined");
  tx = await page.evaluate(
    () =>
      testWallet.calls.filter((x) => x.method === "eth_sendTransaction").at(-1)
        .params[0],
  );
  decoded = interfaces.PlaceRouter.parseTransaction({ data: tx.data });
  assert.equal(decoded.name, "swap");
  assert.equal(decoded.args[0], false);
  assert.equal(decoded.args[1], true);
  assert.equal(decoded.args[3], e.parseEther("0.099"));
  state.allowance = 0n;
  await page.locator("#cancel-review").click();
  await page.locator("#swap-amount").fill("2");
  await expect(page.locator("#swap")).toBeDisabled();
  pass(
    "Sell quote, output currency, paint behavior and input-driven quote invalidation",
  );
  await page.locator("#claim").click();
  await expect(page.locator("#review-content")).toContainText("0.5 IMD");
  await page.locator("#cancel-review").click();
  await page.locator("#withdraw-refund").click();
  await expect(page.locator("#review-content")).toContainText("2.0 IMD");
  await page.locator("#cancel-review").click();
  pass(
    "Trade earnings and bid refund reviews show real contract amounts from the fixture",
  );
  await page.getByRole("button", { name: "Review bid ↗" }).click();
  await expect(page.locator("#review-content")).toContainText("5.25 IMD");
  await page.locator("#cancel-review").click();
  state.auctionEnd = state.time - 1;
  await page.locator("#refresh").click();
  await expect(
    page.getByRole("button", { name: "Settle auction ↗" }),
  ).toBeEnabled();
  await page.getByRole("button", { name: "Settle auction ↗" }).click();
  await expect(page.locator("#review-content")).toContainText(
    "Transfer the NFT",
  );
  await page.locator("#cancel-review").click();
  state.finalized = true;
  await page.locator("#refresh").click();
  await expect(page.locator("#season-1")).toContainText("Sale price: 5.0 IMD");
  await page.getByRole("button", { name: "Review season claim ↗" }).click();
  await expect(page.locator("#review-content")).toContainText(
    "3.5 IMD from 1 final pixels",
  );
  await page.locator("#cancel-review").click();
  pass(
    "Active bid, closed auction settlement, winner/sale price and final-owner season claim review",
  );
  state.start = state.time - 604801;
  await page.locator("#refresh").click();
  await expect(page.locator("#end-season")).toBeEnabled();
  await expect(page.locator("#submit-paint")).toBeDisabled();
  await page.locator("#end-season").click();
  await expect(page.locator("#review-content")).toContainText("start season 3");
  await page.locator("#cancel-review").click();
  pass("Due season enables permissionless ending and disables painting");
  await page.locator("#rank-earned").click();
  await expect(page.locator("#rank-description")).toContainText(
    "Lifetime IMD earned",
  );
  await expect(page.locator("#leaderboard")).toContainText("IMD");
  await page.locator("#rank-owned").click();
  await expect(page.locator("#leaderboard")).toContainText("pixels");
  pass("Ownership and cumulative earnings leaderboard modes");
  await page.evaluate((other) => {
    testWallet.accounts = [other];
    for (const f of testWallet.listeners.accountsChanged || []) f([other]);
  }, other);
  await expect(page.locator("#connect")).toContainText("Connect wallet");
  await expect(page.locator("#drops")).toHaveText("—");
  await expect(page.locator("#swap")).toBeDisabled();
  pass(
    "Wallet account change clears account data and invalidates trade review",
  );
  const axeSource = await readFile(
    require.resolve("axe-core/axe.min.js"),
    "utf8",
  );
  await page.addScriptTag({ content: axeSource });
  for (const width of [320, 390, 680, 768, 1120, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    assert.equal(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
      true,
      "Overflow at " + width,
    );
  }
  for (const width of [390, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    const audit = await page.evaluate(() =>
      axe.run(document, {
        runOnly: {
          type: "tag",
          values: ["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"],
        },
      }),
    );
    const violations = audit.violations.map((v) => ({
      id: v.id,
      impact: v.impact,
      targets: v.nodes.map((n) => n.target),
    }));
    report.accessibility.push({ fixture: true, width, violations });
    assert.equal(violations.length, 0, JSON.stringify(violations));
  }
  await page.evaluate(() => (document.documentElement.dir = "rtl"));
  assert(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  );
  await page.evaluate(() => {
    document.documentElement.dir = "ltr";
    document.documentElement.style.zoom = "2";
  });
  assert(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  );
  await page.evaluate(() => (document.documentElement.style.zoom = ""));
  await page.emulateMedia({ reducedMotion: "reduce" });
  assert.equal(
    await page
      .locator("button")
      .first()
      .evaluate((el) => getComputedStyle(el).transitionDuration),
    "0s",
  );
  assert(await page.evaluate(() => document.fonts.check("600 32px Pixel")));
  pass(
    "Six responsive widths, RTL mirror, 200% CSS zoom, reduced motion, loaded Pixel font and desktop/mobile axe audits",
  );
  assert.deepEqual(report.consoleErrors, []);
  pass("No fixture console errors or uncaught page errors");
  await context.close();
  if (process.env.IMD_LIVE_BROWSER === "1") {
    const live = await browser.newContext({
        viewport: { width: 1440, height: 1000 },
      }),
      p = await live.newPage(),
      errors = [];
    p.on("pageerror", (err) => errors.push(err.message));
    p.on("console", (m) => {
      if (m.type() === "error") errors.push(m.text());
    });
    await p.goto(url);
    await expect(p.locator("#connection")).toContainText("Live ·", {
      timeout: 60000,
    });
    await expect(p.locator("#history-status")).toContainText(
      "indexed through",
      { timeout: 60000 },
    );
    report.liveChecks.push({
      name: "Mainnet canvas and event indexing",
      connection: await p.locator("#connection").textContent(),
      history: await p.locator("#history-status").textContent(),
    });
    await p.locator("#quote").click();
    await expect(p.locator("#quote-info")).toContainText("Expected:", {
      timeout: 30000,
    });
    report.liveChecks.push({
      name: "Disconnected mainnet buy quote",
      result: await p.locator("#quote-info").textContent(),
    });
    await p.locator("#sell-mode").click();
    await p.locator("#quote").click();
    await expect(p.locator("#quote-info")).toContainText(
      /Expected:|not enough liquidity/,
      { timeout: 30000 },
    );
    report.liveChecks.push({
      name: "Disconnected mainnet sell simulation (quote or explicit liquidity rejection)",
      result: await p.locator("#quote-info").textContent(),
    });
    await p.locator("#buy-mode").click();
    await p.evaluate(() => scrollTo(0, 0));
    await p.screenshot({
      path: resolve(root, "docs/validation/desktop.jpg"),
      type: "jpeg",
      quality: 80,
      fullPage: true,
    });
    await p.setViewportSize({ width: 390, height: 844 });
    await p.screenshot({
      path: resolve(root, "docs/validation/mobile.jpg"),
      type: "jpeg",
      quality: 80,
      fullPage: true,
    });
    await p.addScriptTag({ content: axeSource });
    const audit = await p.evaluate(() =>
      axe.run(document, {
        runOnly: {
          type: "tag",
          values: ["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"],
        },
      }),
    );
    report.accessibility.push({
      fixture: false,
      width: 390,
      violations: audit.violations.map((v) => ({
        id: v.id,
        targets: v.nodes.map((n) => n.target),
      })),
    });
    assert.equal(audit.violations.length, 0);
    assert.deepEqual(errors, []);
    report.liveChecks.push({
      name: "Live mobile axe audit and browser console",
      violations: 0,
      consoleErrors: errors,
    });
    await live.close();
  }
  report.passed = true;
} catch (error) {
  report.passed = false;
  report.failure = error.message;
  throw error;
} finally {
  await writeFile(
    resolve(root, "docs/validation/browser-validation.json"),
    JSON.stringify(report, null, 2) + "\n",
  );
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
}
