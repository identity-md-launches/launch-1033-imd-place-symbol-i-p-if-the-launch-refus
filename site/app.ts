import { Contract, ZeroAddress, formatUnits, type JsonRpcSigner } from "ethers";
import {
  canvas,
  config,
  hook,
  imd,
  interfaces,
  nowBlock,
  readOwners,
  router,
  scanHistory,
  seasons,
  simulateSwap,
  token,
  unpack,
  verifyDeployment,
  type History,
  type Pixel,
} from "./chain";
import {
  amountValue,
  format,
  names,
  priceLimit,
  readableError,
  same,
  seasonShare,
  short,
  slippageMinimum,
  togglePixel,
} from "./core";
import { assertWallet, connectWallet, discover, type Wallet } from "./wallet";
const $ = <T extends HTMLElement = HTMLElement>(id: string) => {
  const e = document.getElementById(id);
  if (!e) throw Error("Missing interface element: " + id);
  return e as T;
};
const input = (id: string) => $<HTMLInputElement>(id);
const button = (id: string) => $<HTMLButtonElement>(id);
const walletDialog = $<HTMLDialogElement>("wallet-dialog"),
  reviewDialog = $<HTMLDialogElement>("review-dialog");
const board = $<HTMLCanvasElement>("canvas"),
  ctx = board.getContext("2d")!;
let palette = [
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
].map((x) => "#" + x);
let pixels: Uint8Array = new Uint8Array(4096).fill(255),
  selection = new Map<number, number>(),
  colour = 4,
  focusPixel = -1;
let owners: Pixel[] = [],
  season = 0n,
  seasonStart = 0,
  chainTime = 0,
  syncTime = 0,
  launchTime = 0,
  dropUnit = 50000000000000000n,
  hookFee = 0n,
  imd0 = true;
let account = "",
  signer: JsonRpcSigner | undefined,
  wallets: Wallet[] = [],
  ready = false,
  busy = false,
  live = false;
let drops = 0n,
  claimable = 0n,
  refund = 0n,
  imdBalance = 0n,
  tokenBalance = 0n,
  selectionCost: bigint | undefined,
  selectionRevision = 0;
let zoom = 1,
  pan = [0, 0],
  mode = "select",
  pointer: { id: number; x: number; y: number; pan: number[] } | undefined;
let buy = true,
  quoteRevision = 0;
type Quote = {
  amount: bigint;
  received: bigint;
  spent: bigint;
  minimum: bigint;
  deadline: number;
  buy: boolean;
  fee: bigint;
  account: string;
  drops: bigint;
};
let quote: Quote | undefined;
let reviewAction: (() => Promise<void>) | undefined,
  reviewAccount = "";
let history: History | undefined,
  historyBusy = false,
  historyComplete = false,
  ranking = "owned",
  earned = new Map<string, bigint>();
let refreshing: Promise<void> | undefined,
  galleryFloor = 0,
  galleryLoaded = 0,
  auctionRefresh = false;
const frozenOwners = new Map<string, Pixel[]>(),
  metadata = new Map<string, { image: string; name: string }>();
const now = () => chainTime + Math.floor((Date.now() - syncTime) / 1000);
const error = (e: unknown) => readableError(e, interfaces);
function node<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  text?: string,
  className?: string,
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (className) e.className = className;
  return e;
}
function status(message: string, failed = false) {
  $("notice").textContent = message;
  $("notice").classList.toggle("error", failed);
}
function contractLink(address: string, label: string) {
  const a = node("a", label);
  a.href = config.explorer + "/address/" + address;
  a.target = "_blank";
  a.rel = "noopener";
  a.title = address;
  return a;
}
function controls() {
  const unavailable = !ready || !live || busy;
  button("quote").disabled = unavailable;
  button("swap").disabled = unavailable || !quote || quote.deadline <= now();
  button("submit-paint").disabled =
    unavailable ||
    !selection.size ||
    selectionCost === undefined ||
    now() >= seasonStart + 604800;
  button("claim").disabled = unavailable || !account || claimable === 0n;
  button("withdraw-refund").disabled = unavailable || !account || refund === 0n;
  button("end-season").disabled = unavailable || now() < seasonStart + 604800;
  button("refresh").disabled = busy;
  button("more-seasons").disabled = busy;
  for (const b of document.querySelectorAll<HTMLButtonElement>(
    "[data-tx-ready]",
  ))
    b.disabled = unavailable || b.dataset.txReady !== "true";
  for (const b of $("wallet-options").querySelectorAll("button"))
    b.disabled = busy;
  button("connect").disabled = busy;
  button("confirm-review").disabled = busy;
  button("cancel-review").disabled = busy;
  button("close-review").disabled = busy;
  button("confirm-review").textContent = busy
    ? "Waiting for wallet…"
    : "Confirm in wallet ↗";
  reviewDialog.setAttribute("aria-busy", String(busy));
}
async function run(fn: () => Promise<void>) {
  if (busy) return;
  busy = true;
  controls();
  try {
    await fn();
  } catch (e) {
    status(error(e), true);
    if (reviewDialog.open) $("review-error").textContent = error(e);
  } finally {
    busy = false;
    controls();
    if (reviewDialog.open && document.activeElement === reviewDialog)
      button("cancel-review").focus();
  }
}
function resetAccount() {
  account = "";
  signer = undefined;
  quote = undefined;
  quoteRevision++;
  drops = claimable = refund = imdBalance = tokenBalance = 0n;
  $("connect").textContent = "Connect wallet ↗";
  for (const id of ["drops", "earnings", "refunds", "lifetime"])
    $(id).textContent = "—";
  $("token-balances").textContent =
    "Connect your wallet to see your token balances.";
  if (!busy) reviewDialog.close();
  renderCommunity();
  controls();
}
function requireAccount() {
  if (!account || !signer) {
    walletDialog.showModal();
    throw Error("Connect your wallet, then review your transaction.");
  }
}
function showReview(
  title: string,
  lines: string[],
  action: () => Promise<void>,
) {
  requireAccount();
  reviewAccount = account;
  reviewAction = action;
  $("review-title").textContent = title;
  $("review-content").replaceChildren(...lines.map((line) => node("p", line)));
  $("review-error").textContent = "";
  reviewDialog.showModal();
  button("cancel-review").focus();
}
button("confirm-review").onclick = () =>
  void run(async () => {
    if (!reviewAction) return;
    await assertWallet(reviewAccount);
    if (!same(account, reviewAccount))
      throw Error("Your account changed. Close this review and reconnect.");
    await reviewAction();
    reviewDialog.close();
    reviewAction = undefined;
    await refresh();
    void refreshHistory();
  });
for (const id of ["close-review", "cancel-review"])
  button(id).onclick = () => reviewDialog.close();
reviewDialog.addEventListener("cancel", (e) => {
  if (busy) e.preventDefault();
});
button("connect").onclick = () => {
  walletDialog.showModal();
  window.dispatchEvent(new Event("eip6963:requestProvider"));
};
button("close-wallet").onclick = () => walletDialog.close();
discover(
  (found) => {
    wallets = found;
    const options = $("wallet-options");
    options.replaceChildren();
    if (!wallets.length)
      options.append(
        node(
          "p",
          "No browser wallet found. Open this address in MetaMask, Rabby, Coinbase Wallet or another wallet browser.",
          "muted",
        ),
      );
    for (const wallet of wallets) {
      const b = node("button", "Connect " + wallet.name);
      b.onclick = () =>
        void run(async () => {
          const connected = await connectWallet(wallet);
          signer = connected.signer;
          account = connected.account;
          quote = undefined;
          quoteRevision++;
          $("connect").textContent = short(account);
          walletDialog.close();
          await refresh();
          status(
            "Connected on Robinhood Chain. Your wallet will review each transaction.",
          );
        });
      options.append(b);
    }
  },
  () => {
    resetAccount();
    status("Your wallet account or network changed. Reconnect to continue.");
  },
);
async function send(contract: Contract, method: string, args: unknown[] = []) {
  requireAccount();
  const expected = account;
  await assertWallet(expected);
  const connected = contract.connect(signer!) as Contract;
  await connected[method].staticCall(...args);
  await assertWallet(expected);
  const labels: Record<string, string> = {
    approve: "the token approval",
    swap: "your trade",
    paintWithLimit: "your paint transaction",
    claim: "your earnings claim",
    withdrawRefund: "your refund withdrawal",
    bid: "your auction bid",
    finalize: "the auction settlement",
    endSeason: "the season ending",
  };
  status("Confirm " + (labels[method] || "this transaction") + " in your wallet.");
  const tx = await connected[method](...args);
  status("Submitted " + short(tx.hash) + " · waiting for confirmation.");
  $("notice").append(
    " ",
    (() => {
      const a = node("a", "View transaction ↗");
      a.href = config.explorer + "/tx/" + tx.hash;
      a.target = "_blank";
      a.rel = "noopener";
      return a;
    })(),
  );
  const receipt = await tx.wait();
  if (receipt?.status !== 1)
    throw Error(
      "The transaction reverted. Refresh and review the latest state.",
    );
  status("Transaction confirmed. Refreshing the canvas…");
  return receipt;
}
async function approve(
  asset: Contract,
  spender: string,
  amount: bigint,
  symbol: string,
) {
  if ((await asset.balanceOf(account)) < amount)
    throw Error(
      `Not enough ${symbol}. Check your balance and reduce the amount.`,
    );
  if ((await asset.allowance(account, spender)) < amount) {
    status(
      `Approve exactly ${formatUnits(amount, 18)} ${symbol} in your wallet. A second confirmation will submit the transaction.`,
    );
    await send(asset, "approve", [spender, amount]);
  }
}
function draw() {
  ctx.clearRect(0, 0, 1024, 1024);
  for (let id = 0; id < 4096; id++) {
    const x = id % 64,
      y = Math.floor(id / 64),
      c = selection.get(id) ?? pixels[id];
    ctx.fillStyle = c < 16 ? palette[c] : (x + y) % 2 ? "#1d1d27" : "#171720";
    ctx.fillRect(x * 16, y * 16, 16, 16);
  }
  ctx.strokeStyle = "#fff";
  ctx.lineWidth = 2;
  for (const id of selection.keys())
    ctx.strokeRect((id % 64) * 16 + 2, Math.floor(id / 64) * 16 + 2, 12, 12);
  if (focusPixel >= 0) {
    ctx.strokeStyle = "#ffd635";
    ctx.lineWidth = 3;
    ctx.strokeRect(
      (focusPixel % 64) * 16 + 1,
      Math.floor(focusPixel / 64) * 16 + 1,
      14,
      14,
    );
  }
}
function drawPalette() {
  $("palette").replaceChildren(
    ...palette.map((hex, i) => {
      const b = node("button", undefined, "swatch");
      b.style.background = hex;
      b.title = names[i];
      b.setAttribute("aria-label", names[i]);
      b.setAttribute("aria-pressed", String(colour === i));
      b.onclick = () => {
        colour = i;
        for (const [index, swatch] of [...$("palette").children].entries())
          swatch.setAttribute("aria-pressed", String(index === colour));
        $("colour-name").textContent = names[i];
      };
      return b;
    }),
  );
}
function transform() {
  const r = $("viewport").getBoundingClientRect();
  pan = pan.map((v, i) =>
    Math.max(
      (-[r.width, r.height][i] * zoom) / 2,
      Math.min(([r.width, r.height][i] * zoom) / 2, v),
    ),
  );
  board.style.transform = `translate(${pan[0]}px,${pan[1]}px) scale(${zoom})`;
  input("zoom").value = String(zoom);
  $("zoom-label").textContent = zoom + "×";
}
async function pixelInfo(id: number) {
  if (!ready) return;
  const current = season;
  const [p, price] = await Promise.all([
    canvas.pixels(current, id),
    canvas.price(id),
  ]);
  if (id !== focusPixel || current !== season) return;
  const active = now() < Number(p.windowStart) + 86400;
  const info = $("pixel-info");
  info.replaceChildren(
    "Owner: ",
    same(p.owner, ZeroAddress)
      ? node("span", "Unpainted")
      : contractLink(p.owner, short(p.owner)),
    node("br"),
    `${active ? p.paints : 0} paints in this 24-hour window · ${price} drops to paint now.`,
  );
}
async function updateSelection() {
  const revision = ++selectionRevision;
  selectionCost = undefined;
  $("selection-count").textContent =
    `${selection.size} ${selection.size === 1 ? "pixel" : "pixels"} selected`;
  $("paint-cost").textContent = selection.size ? "Checking…" : "0 drops";
  draw();
  controls();
  if (!selection.size) {
    selectionCost = 0n;
    return;
  }
  if (!ready) return;
  await new Promise((resolve) => setTimeout(resolve, 120));
  if (revision !== selectionRevision) return;
  try {
    const costs: bigint[] = await Promise.all(
      [...selection.keys()].map((id) => canvas.price(id)),
    );
    if (revision !== selectionRevision) return;
    selectionCost = costs.reduce((a, b) => a + b, 0n);
    $("paint-cost").textContent = selectionCost + " drops";
    controls();
  } catch (e) {
    if (revision === selectionRevision) {
      $("paint-cost").textContent = "Unavailable";
      status("Could not load paint cost. Refresh to try again.", true);
    }
  }
}
async function choose(id: number) {
  togglePixel(selection, id, colour);
  focusPixel = id;
  input("coord-x").value = String(id % 64);
  input("coord-y").value = String(Math.floor(id / 64));
  $("pixel-title").textContent = `Pixel (${id % 64}, ${Math.floor(id / 64)})`;
  draw();
  await Promise.all([updateSelection(), pixelInfo(id)]);
}
const chooseSafe = (id: number) =>
  void choose(id).catch((e) => status(error(e), true));
board.addEventListener("pointerdown", (e) => {
  board.setPointerCapture(e.pointerId);
  pointer = { id: e.pointerId, x: e.clientX, y: e.clientY, pan: [...pan] };
});
board.addEventListener("pointermove", (e) => {
  if (pointer?.id === e.pointerId && mode === "pan") {
    pan = [
      pointer.pan[0] + e.clientX - pointer.x,
      pointer.pan[1] + e.clientY - pointer.y,
    ];
    transform();
  }
});
board.addEventListener("pointerup", (e) => {
  if (pointer?.id !== e.pointerId) return;
  if (
    mode === "select" &&
    Math.hypot(e.clientX - pointer.x, e.clientY - pointer.y) < 10
  ) {
    const r = board.getBoundingClientRect(),
      x = Math.floor(((e.clientX - r.left) / r.width) * 64),
      y = Math.floor(((e.clientY - r.top) / r.height) * 64);
    if (x >= 0 && x < 64 && y >= 0 && y < 64) chooseSafe(y * 64 + x);
  }
  pointer = undefined;
});
board.addEventListener("pointercancel", () => (pointer = undefined));
board.addEventListener("keydown", (e) => {
  const arrows: Record<string, number[]> = {
    ArrowLeft: [-1, 0],
    ArrowRight: [1, 0],
    ArrowUp: [0, -1],
    ArrowDown: [0, 1],
  };
  if (arrows[e.key]) {
    e.preventDefault();
    const [dx, dy] = arrows[e.key];
    if (mode === "pan") {
      pan = [pan[0] - dx * 32, pan[1] - dy * 32];
      transform();
      return;
    }
    const current = Math.max(0, focusPixel),
      x = Math.max(0, Math.min(63, (current % 64) + dx)),
      y = Math.max(0, Math.min(63, Math.floor(current / 64) + dy));
    focusPixel = y * 64 + x;
    input("coord-x").value = String(x);
    input("coord-y").value = String(y);
    $("pixel-title").textContent = `Pixel (${x}, ${y})`;
    draw();
    void pixelInfo(focusPixel).catch((e) => status(error(e), true));
  } else if (e.key === "Enter" || e.key === " ") {
    e.preventDefault();
    chooseSafe(Math.max(0, focusPixel));
  }
});
$("viewport").addEventListener(
  "wheel",
  (e) => {
    if (!e.ctrlKey && !e.metaKey) return;
    e.preventDefault();
    zoom = Math.max(1, Math.min(8, zoom + (e.deltaY < 0 ? 0.25 : -0.25)));
    transform();
  },
  { passive: false },
);
input("zoom").oninput = () => {
  zoom = Number(input("zoom").value);
  transform();
};
button("reset-view").onclick = () => {
  zoom = 1;
  pan = [0, 0];
  transform();
};
for (const m of ["paint", "pan"])
  button(m + "-mode").onclick = () => {
    mode = m === "paint" ? "select" : "pan";
    for (const id of ["paint", "pan"])
      button(id + "-mode").setAttribute("aria-pressed", String(m === id));
    board.style.cursor = m === "pan" ? "grab" : "crosshair";
  };
button("choose-coordinate").onclick = () => {
  const x = Number(input("coord-x").value),
    y = Number(input("coord-y").value);
  if (
    input("coord-x").value === "" ||
    input("coord-y").value === "" ||
    !Number.isInteger(x) ||
    !Number.isInteger(y) ||
    x < 0 ||
    x > 63 ||
    y < 0 ||
    y > 63
  ) {
    status("Choose X and Y coordinates from 0 to 63.", true);
    input("coord-x").focus();
    return;
  }
  chooseSafe(y * 64 + x);
};
button("clear-selection").onclick = () => {
  selection.clear();
  void updateSelection();
};
button("submit-paint").onclick = () =>
  void run(async () => {
    requireAccount();
    const ids = [...selection.keys()],
      colours = [...selection.values()],
      revision = selectionRevision;
    const costs: bigint[] = await Promise.all(
        ids.map((id) => canvas.price(id)),
      ),
      cost = costs.reduce((a, b) => a + b, 0n),
      balance: bigint = await canvas.drops(account);
    if (revision !== selectionRevision)
      throw Error("Your selection changed. Review paint again.");
    if (balance < cost)
      throw Error(
        `Not enough paint: ${cost} drops needed, ${balance} available. Buy i/p or select fewer pixels.`,
      );
    const paintSeason = season;
    showReview(
      "Paint " + ids.length + " pixels",
      [
        `Maximum paint cost: ${cost} drops. Available: ${balance} drops.`,
        `Season ${season} · ${ids.length} distinct pixels · colour choices shown on the canvas.`,
        `Painter: ${account}`,
      ],
      async () => {
        if ((await canvas.currentSeason()) !== paintSeason)
          throw Error(
            "The season changed. Close this review and select pixels again.",
          );
        await send(canvas, "paintWithLimit", [ids, colours, cost]);
        selection.clear();
        await updateSelection();
      },
    );
  });
function invalidateQuote() {
  quote = undefined;
  quoteRevision++;
  $("quote-info").textContent = "Get a fresh quote to review this amount.";
  controls();
}
for (const id of ["swap-amount", "slippage"])
  input(id).oninput = () => {
    invalidateQuote();
    $("swap-error").textContent = "";
    input(id).removeAttribute("aria-invalid");
  };
for (const direction of ["buy", "sell"])
  button(direction + "-mode").onclick = () => {
    buy = direction === "buy";
    invalidateQuote();
    button("buy-mode").setAttribute("aria-pressed", String(buy));
    button("sell-mode").setAttribute("aria-pressed", String(!buy));
    $("amount-label").textContent = buy ? "Spend IMD" : "Sell i/p";
    $("trade-title").textContent = buy ? "Buy paint" : "Sell i/p";
    $("trade-help").textContent = buy
      ? "Every 0.05 IMD spent buying i/p earns 1 drop."
      : "Receive IMD for your i/p. Your remaining paint stays yours.";
    button("swap").textContent = buy ? "Review buy ↗" : "Review sell ↗";
  };
$("swap-form").onsubmit = (e) => {
  e.preventDefault();
  void run(async () => {
    $("swap-error").textContent = "";
    for (const id of ["swap-amount", "slippage"])
      input(id).removeAttribute("aria-invalid");
    let amount: bigint;
    try {
      amount = amountValue(input("swap-amount").value);
    } catch (e) {
      input("swap-amount").setAttribute("aria-invalid", "true");
      input("swap-amount").focus();
      $("swap-error").textContent = error(e);
      return;
    }
    try {
      slippageMinimum(10n ** 18n, input("slippage").value);
    } catch (e) {
      input("slippage").setAttribute("aria-invalid", "true");
      input("slippage").focus();
      $("swap-error").textContent = error(e);
      return;
    }
    const revision = ++quoteRevision,
      direction = buy,
      quoteAccount = account,
      slippage = input("slippage").value;
    quote = undefined;
    $("quote-info").textContent = "Simulating the trade through PlaceRouter…";
    try {
      const block = await nowBlock(),
        deadline = block.timestamp + 120;
      const [result, fee] = await Promise.all([
        simulateSwap(
          direction,
          amount,
          priceLimit(direction, imd0),
          deadline,
          account || config.contracts.router,
        ),
        hook.feeBps(),
      ]);
      if (
        revision !== quoteRevision ||
        !same(
          quoteAccount || config.contracts.router,
          account || config.contracts.router,
        )
      )
        return;
      const [spent, received] = result,
        minimum = slippageMinimum(received, slippage);
      quote = {
        amount,
        spent,
        received,
        minimum,
        deadline,
        buy: direction,
        fee,
        account: quoteAccount,
        drops: direction ? spent / dropUnit : 0n,
      };
      $("quote-info").replaceChildren(
        node("b", `Expected: ${format(received)} ${direction ? "i/p" : "IMD"}`),
        node(
          "p",
          `Minimum received: ${formatUnits(minimum, 18)} ${direction ? "i/p" : "IMD"}.`,
        ),
        node(
          "p",
          direction
            ? `Paint credited: ${quote.drops} drops.`
            : "No paint is credited or consumed.",
        ),
        node(
          "p",
          `Hook fee at quote: ${Number(fee) / 100}%. Pool fee: 1.25%. Valid for 2 minutes.`,
        ),
      );
      status("Quote ready. Review it before approving any tokens.");
    } catch (e) {
      $("quote-info").textContent = error(e);
      throw e;
    }
  });
};
button("swap").onclick = () =>
  void run(async () => {
    requireAccount();
    const q = quote;
    if (!q || q.deadline <= now())
      throw Error("This quote expired. Get a new quote.");
    if (q.account && !same(q.account, account))
      throw Error("Get a fresh quote for this wallet.");
    const symbol = q.buy ? "IMD" : "i/p",
      asset = q.buy ? imd : token;
    const allowance: bigint = await asset.allowance(
        account,
        config.contracts.router,
      ),
      balance: bigint = await asset.balanceOf(account);
    if (balance < q.amount)
      throw Error(
        `Not enough ${symbol}. Available: ${format(balance)}. Reduce the amount and quote again.`,
      );
    showReview(
      q.buy ? "Buy i/p + paint" : "Sell i/p",
      [
        `Spend at most ${formatUnits(q.amount, 18)} ${symbol}.`,
        `Receive at least ${formatUnits(q.minimum, 18)} ${q.buy ? "i/p" : "IMD"}.`,
        q.buy
          ? `Expected paint: ${q.drops} drops.`
          : "Paint balance stays unchanged.",
        `Hook fee at quote: ${Number(q.fee) / 100}% + 1.25% pool fee.`,
        allowance < q.amount
          ? `First approve exactly ${formatUnits(q.amount, 18)} ${symbol} to PlaceRouter. Then confirm the swap.`
          : "Your existing router allowance covers this amount.",
      ],
      async () => {
        if (q.deadline <= now())
          throw Error(
            "This quote expired. Close the review and get a new quote.",
          );
        await approve(asset, config.contracts.router, q.amount, symbol);
        if (q.deadline <= (await nowBlock()).timestamp)
          throw Error(
            "Approval confirmed, but the quote expired. Get a new quote; your approval remains available.",
          );
        await send(router, "swap", [
          q.buy,
          true,
          q.amount,
          q.minimum,
          priceLimit(q.buy, imd0),
          q.deadline,
        ]);
        invalidateQuote();
      },
    );
  });
button("claim").onclick = () =>
  void run(async () =>
    showReview(
      "Claim trade earnings",
      [
        `Claimable: ${formatUnits(claimable, 18)} IMD.`,
        `Receive earnings in ${account}.`,
      ],
      async () => {
        await send(canvas, "claim");
      },
    ),
  );
button("withdraw-refund").onclick = () =>
  void run(async () =>
    showReview(
      "Withdraw bid refund",
      [`Withdraw ${formatUnits(refund, 18)} IMD to ${account}.`],
      async () => {
        await send(seasons, "withdrawRefund");
      },
    ),
  );
button("end-season").onclick = () =>
  void run(async () => {
    requireAccount();
    const id = season,
      needsFinalize = id > 1n && !(await seasons.rolloverResolved(id - 1n));
    showReview(
      "End season " + id,
      [
        `Freeze this canvas as a 1/1 NFT and start season ${id + 1n}.`,
        needsFinalize
          ? "The previous unbid auction must be settled first. Your wallet will receive two requests."
          : "A 24-hour auction will open for this canvas.",
      ],
      async () => {
        if ((await canvas.currentSeason()) !== id)
          throw Error("Someone already ended this season. Refresh the canvas.");
        if (needsFinalize) await send(seasons, "finalize", [id - 1n]);
        await send(canvas, "endSeason");
        selection.clear();
        await updateSelection();
      },
    );
  });
function tick() {
  if (!season) return;
  const remaining = Math.max(0, seasonStart + 604800 - now());
  $("timer").textContent = remaining
    ? `${Math.floor(remaining / 86400)}d ${String(Math.floor(remaining / 3600) % 24).padStart(2, "0")}h ${String(Math.floor(remaining / 60) % 60).padStart(2, "0")}m`
    : "Ready to freeze";
  $("season-state").textContent = remaining
    ? "Until this canvas becomes a one-of-one."
    : "Painting is closed. Anyone can end this season.";
  if (quote && quote.deadline <= now()) {
    $("quote-info").append(node("p", "Quote expired. Get a new quote."));
    quote = undefined;
  }
  controls();
}
function renderCommunity() {
  const counts = new Map<string, number>();
  owners.forEach((p) => {
    if (!same(p.owner, ZeroAddress)) {
      const a = p.owner.toLowerCase();
      counts.set(a, (counts.get(a) || 0) + 1);
    }
  });
  const ranks =
    ranking === "owned"
      ? [...counts.entries()].map(([a, n]) => [a, BigInt(n)] as const)
      : [...earned.entries()];
  ranks.sort((a, b) =>
    a[1] === b[1] ? a[0].localeCompare(b[0]) : a[1] > b[1] ? -1 : 1,
  );
  $("leaderboard").replaceChildren(
    ...ranks
      .filter(([, v]) => v > 0n)
      .slice(0, 20)
      .map(([a, n], i) => {
        const li = node("li");
        li.append(
          contractLink(a, `${String(i + 1).padStart(2, "0")} / ${short(a)}`),
          node("b", ranking === "owned" ? n + " pixels" : format(n) + " IMD"),
        );
        return li;
      }),
  );
  if (!$("leaderboard").children.length)
    $("leaderboard").append(
      node(
        "li",
        ranking === "earned" && !historyComplete
          ? "Indexing lifetime earnings…"
          : "No painters in this ranking yet. Make your mark on the canvas.",
        "empty",
      ),
    );
  const mine = owners.flatMap((p, id) => (same(p.owner, account) ? [id] : []));
  $("my-count").textContent = account ? String(mine.length) : "—";
  $("my-pixels").replaceChildren(
    ...mine.map((id) => {
      const b = node("button", `(${id % 64}, ${Math.floor(id / 64)})`);
      b.onclick = () => {
        chooseSafe(id);
        $("play").scrollIntoView();
        board.focus({ preventScroll: true });
      };
      return b;
    }),
  );
  if (!mine.length)
    $("my-pixels").append(
      node(
        "p",
        account
          ? "No pixels owned yet. Select a colour and claim your first pixel."
          : "Connect your wallet to find your place.",
        "muted",
      ),
    );
  $("lifetime").textContent =
    account && historyComplete
      ? format(earned.get(account.toLowerCase()) || 0n) + " IMD"
      : "—";
}
for (const rank of ["owned", "earned"])
  button("rank-" + rank).onclick = () => {
    ranking = rank;
    button("rank-owned").setAttribute("aria-pressed", String(rank === "owned"));
    button("rank-earned").setAttribute(
      "aria-pressed",
      String(rank === "earned"),
    );
    $("rank-description").textContent =
      rank === "owned"
        ? "Current pixel owners, refreshed with the canvas."
        : "Lifetime IMD earned = claims paid + claimable trade fees + unclaimed payouts from settled seasons. Recent claims wait 12 blocks for indexing.";
    renderCommunity();
  };
async function immutableOwners(id: bigint) {
  const key = id.toString();
  let all = frozenOwners.get(key);
  if (!all) {
    all = await readOwners(id);
    frozenOwners.set(key, all);
  }
  return all;
}
async function unclaimedPixels(id: bigint, artist: string) {
  const [all, bits] = await Promise.all([
    immutableOwners(id),
    Promise.all(
      Array.from({ length: 16 }, (_, i) => seasons.claimedBitmap(id, i)),
    ),
  ]);
  return all.flatMap((p, i) =>
    same(p.owner, artist) && !(bits[i >> 8] & (1n << BigInt(i & 255)))
      ? [i]
      : [],
  );
}
async function refreshHistory() {
  if (!ready || historyBusy) return;
  historyBusy = true;
  try {
    const block = await nowBlock();
    history = await scanHistory(block.number, (message) => {
      $("history-status").textContent = message;
    });
    $("total-credited").textContent = BigInt(history.credited).toLocaleString();
    const artists = [
      ...new Set([
        ...history.artists,
        ...owners
          .filter((p) => !same(p.owner, ZeroAddress))
          .map((p) => p.owner.toLowerCase()),
        ...(account ? [account.toLowerCase()] : []),
      ]),
    ];
    const next = new Map<string, bigint>();
    for (let start = 0; start < artists.length; start += 20) {
      await Promise.all(
        artists.slice(start, start + 20).map(async (a) => {
          next.set(
            a,
            BigInt(history!.claimed[a] || 0) + (await canvas.claimable(a)),
          );
        }),
      );
    }
    for (let id = 1n; id < season; id++) {
      const a = await seasons.auctions(id);
      if (!a.finalized || a.highBid === 0n) continue;
      const [all, bits] = await Promise.all([
        immutableOwners(id),
        Promise.all(
          Array.from({ length: 16 }, (_, i) => seasons.claimedBitmap(id, i)),
        ),
      ]);
      all.forEach((p, i) => {
        if (
          same(p.owner, ZeroAddress) ||
          bits[i >> 8] & (1n << BigInt(i & 255))
        )
          return;
        const owner = p.owner.toLowerCase(),
          value = seasonShare(a.payout, a.occupied, [p.rank]);
        next.set(owner, (next.get(owner) || 0n) + value);
      });
    }
    earned = next;
    historyComplete = true;
    $("history-status").textContent =
      `Event totals indexed through block ${history.to.toLocaleString()} · 12-block confirmation delay. Live balances may include newer activity.`;
    renderCommunity();
  } catch (e) {
    historyComplete = false;
    $("history-status").textContent =
      "Event history unavailable: " +
      error(e) +
      " Refresh to retry. Lifetime totals may be incomplete.";
    $("total-credited").textContent = history
      ? formatUnits(BigInt(history.credited), 0) + " (partial)"
      : "Unavailable";
    renderCommunity();
  } finally {
    historyBusy = false;
  }
}
async function artwork(id: bigint) {
  const key = id.toString();
  let m = metadata.get(key);
  if (!m) {
    const uri: string = await seasons.tokenURI(id, { gasLimit: 50_000_000n });
    if (!uri.startsWith("data:application/json;base64,"))
      throw Error("Unsupported on-chain metadata format.");
    const parsed = JSON.parse(atob(uri.split(",")[1]));
    if (!/^data:image\/svg\+xml;base64,[A-Za-z0-9+/=]+$/.test(parsed.image))
      throw Error("Unsupported on-chain artwork format.");
    m = { image: parsed.image, name: String(parsed.name) };
    metadata.set(key, m);
  }
  return m;
}
async function auctionCard(id: bigint) {
  const a = await seasons.auctions(id),
    card = node("article", undefined, "art-card");
  card.id = "season-" + id;
  try {
    const art = await artwork(id),
      image = node("img");
    image.src = art.image;
    image.alt = art.name;
    image.loading = "lazy";
    card.append(image);
  } catch {
    card.append(
      node(
        "p",
        "On-chain artwork could not load. Refresh to try again.",
        "muted",
      ),
    );
  }
  card.append(
    node("h3", "Season " + id),
    node(
      "p",
      `${a.painters} painters · ${a.paints} paints · ${a.occupied} final pixels`,
    ),
  );
  const stats = node(
    "p",
    `Season pot: ${format(a.pot)} IMD. ${a.finalized ? "Sale price" : "Highest bid"}: ${formatUnits(a.highBid, 18)} IMD.`,
  );
  card.append(stats);
  if (a.highBid > 0n) {
    const winner = node(
      "p",
      a.finalized ? "Winner: " : "Highest bidder: ",
      "winner",
    );
    winner.append(contractLink(a.bidder, short(a.bidder)));
    card.append(winner);
  }
  if (!a.finalized && Number(a.end) > now() && a.occupied > 0n) {
    card.append(
      node(
        "p",
        "Auction ends " + new Date(Number(a.end) * 1000).toLocaleString(),
      ),
    );
    const min: bigint = await seasons.minimumBid(id),
      label = node("label", "Bid in IMD"),
      field = node("input");
    field.type = "text";
    field.inputMode = "decimal";
    field.id = "bid-" + id;
    field.value = formatUnits(min, 18);
    label.htmlFor = field.id;
    card.append(
      node("p", "Minimum bid: " + formatUnits(min, 18) + " IMD"),
      label,
      field,
    );
    const b = node("button", "Review bid ↗");
    b.onclick = () =>
      void run(async () => {
        requireAccount();
        const amount = amountValue(field.value),
          minimum: bigint = await seasons.minimumBid(id);
        if (amount < minimum)
          throw Error(`Bid at least ${formatUnits(minimum, 18)} IMD.`);
        showReview(
          "Bid on season " + id,
          [
            `Bid ${formatUnits(amount, 18)} IMD.`,
            `Approve this amount to Seasons if needed, then confirm your bid. If outbid, you can withdraw your refund.`,
            `A bid in the final 10 minutes extends the auction by 10 minutes.`,
          ],
          async () => {
            await approve(imd, config.contracts.seasons, amount, "IMD");
            await send(seasons, "bid", [id, amount]);
            await loadGallery(true);
          },
        );
      });
    card.append(b);
  } else if (!a.finalized) {
    const b = node("button", "Settle auction ↗");
    b.disabled = Number(a.end) > now();
    b.onclick = () =>
      void run(async () =>
        showReview(
          "Settle season " + id,
          [
            a.highBid > 0n
              ? "Transfer the NFT to the winner and unlock artist payouts."
              : "Resolve the unbid auction and carry its pot into the current season.",
          ],
          async () => {
            await send(seasons, "finalize", [id]);
            await loadGallery(true);
          },
        ),
      );
    card.append(b);
  } else if (a.highBid === 0n) {
    const p = node(
      "p",
      a.occupied > 0n
        ? "No bids. Awarded to top painter: "
        : "Blank canvas. NFT remains in season escrow.",
    );
    if (a.occupied > 0n)
      p.append(contractLink(a.topPainter, short(a.topPainter)));
    card.append(p);
  } else {
    const b = node("button", "Review season claim ↗");
    b.onclick = () =>
      void run(async () => {
        requireAccount();
        const ids = await unclaimedPixels(id, account);
        if (!ids.length)
          throw Error(
            "No unclaimed final pixels for this wallet in this season.",
          );
        const all = await immutableOwners(id),
          credit = seasonShare(
            a.payout,
            a.occupied,
            ids.map((i) => all[i].rank),
          );
        showReview(
          "Claim season " + id,
          [
            `Claim ${formatUnits(credit, 18)} IMD from ${ids.length} final pixels.`,
            `${Math.ceil(ids.length / 50)} transaction(s), with up to 50 pixels per transaction. If interrupted, paid pixels are skipped when you retry.`,
          ],
          async () => {
            for (let i = 0; i < ids.length; i += 50)
              await send(seasons, "claim", [id, ids.slice(i, i + 50)]);
            await loadGallery(true);
          },
        );
      });
    card.append(
      node("p", "Auction settled. Final pixel owners can claim their share."),
      b,
    );
  }
  const link = node("a", "View season " + id + " NFT ↗");
  link.href = config.explorer + "/nft/" + config.contracts.seasons + "/" + id;
  link.target = "_blank";
  link.rel = "noopener";
  card.appendChild(node("p")).append(link);
  for (const b of card.querySelectorAll("button")) {
    b.dataset.txReady = String(!b.disabled);
    b.disabled = busy || !ready || !live || b.dataset.txReady !== "true";
  }
  return card;
}
async function loadGallery(reset = false) {
  if (season < 2n) {
    $("gallery").replaceChildren();
    const empty = node("div", undefined, "empty-gallery");
    empty.append(
      node("span", "▦", "pixel-spark"),
      node("h3", "History starts here."),
      node("p", "The first canvas will appear here when season 1 ends."),
    );
    const a = node("a", "Explore the live canvas ↑");
    a.href = "#play";
    empty.append(a);
    $("gallery").append(empty);
    button("more-seasons").hidden = true;
    galleryLoaded = 0;
    return;
  }
  if (auctionRefresh) return;
  auctionRefresh = true;
  try {
    const start = reset ? Number(season) - 1 : galleryFloor,
      end = reset
        ? Math.max(1, start - Math.max(3, galleryLoaded) + 1)
        : Math.max(1, start - 2),
      cards = [];
    for (let id = start; id >= end; id--)
      cards.push(await auctionCard(BigInt(id)));
    if (reset) $("gallery").replaceChildren(...cards);
    else $("gallery").append(...cards);
    galleryLoaded = reset ? cards.length : galleryLoaded + cards.length;
    galleryFloor = end - 1;
    button("more-seasons").hidden = galleryFloor < 1;
  } finally {
    auctionRefresh = false;
    controls();
  }
}
button("more-seasons").onclick = () => void run(() => loadGallery());
async function refreshAuctionSummary() {
  const area = $("current-auction");
  area.replaceChildren(node("h3", "Latest auction"));
  if (season < 2n) {
    area.append(
      node("p", "The first auction opens when this season ends.", "muted"),
    );
    return;
  }
  const id = season - 1n,
    a = await seasons.auctions(id);
  area.append(
    node(
      "p",
      `Season ${id} · ${a.finalized ? "Settled" : Number(a.end) <= now() ? "Ready to settle" : "Bidding open"}`,
    ),
    node("p", `Highest bid: ${formatUnits(a.highBid, 18)} IMD`),
  );
  if (a.highBid > 0n) area.append(contractLink(a.bidder, short(a.bidder)));
  const link = node("a", "View auction & bids ↓");
  link.href = "#season-" + id;
  area.appendChild(node("p")).append(link);
}
async function refresh(forceGallery = false) {
  if (!ready) return;
  if (refreshing) {
    await refreshing;
    if (forceGallery) return refresh(true);
    return;
  }
  refreshing = (async () => {
    try {
      const previous = season,
        expected = account;
      const [id, start, block, total, pot, paid, fee] = await Promise.all([
        canvas.currentSeason(),
        canvas.seasonStart(),
        nowBlock(),
        canvas.totalPaid(),
        canvas.seasonPot(),
        seasons.totalPaid(),
        hook.feeBps(),
      ]);
      season = id;
      seasonStart = Number(start);
      chainTime = block.timestamp;
      syncTime = Date.now();
      hookFee = fee;
      const [colours, s] = await Promise.all([
        canvas.coloursOf(id),
        canvas.stats(id),
      ]);
      pixels = unpack(colours);
      if (pixels.length !== 4096)
        throw Error("Invalid canvas size returned by the chain.");
      owners = s.occupied === 0n ? [] : await readOwners(id);
      if (previous !== season) {
        selection.clear();
        await updateSelection();
      }
      $("season-label").textContent = "Season " + id;
      $("occupied").textContent = `${s.occupied} / 4,096 pixels`;
      $("total-paints").textContent = BigInt(s.paints).toLocaleString();
      $("pot").textContent = format(pot);
      $("total-paid").textContent = format(total + paid);
      $("board-caption").textContent =
        s.occupied === 0n
          ? "A blank canvas. Make the first mark."
          : `${s.occupied} pixels claimed · select one to make it yours.`;
      $("season-deadline").textContent =
        "Ends " + new Date((seasonStart + 604800) * 1000).toLocaleString();
      const decayLeft = Math.max(0, launchTime + 1800 - chainTime);
      $("fee-info").textContent =
        `Hook fee now: ${Number(fee) / 100}%. Pool fee: 1.25%. ${decayLeft ? `Launch fee falls from 35% to 2%; ${Math.ceil(decayLeft / 60)} minutes remain.` : "Launch decay is complete; the hook fee is 2%."}`;
      if (expected) {
        const values = await Promise.all([
          canvas.drops(expected),
          canvas.claimable(expected),
          seasons.pendingRefunds(expected),
          imd.balanceOf(expected),
          token.balanceOf(expected),
        ]);
        if (same(expected, account)) {
          [drops, claimable, refund, imdBalance, tokenBalance] = values;
          $("drops").textContent = drops.toLocaleString();
          $("earnings").textContent = format(claimable);
          $("refunds").textContent = format(refund) + " IMD";
          $("token-balances").textContent =
            `Available: ${format(imdBalance)} IMD · ${format(tokenBalance)} i/p`;
        }
      }
      live = true;
      $("connection").textContent =
        `Live · Robinhood Chain · block ${block.number.toLocaleString()}`;
      if (focusPixel >= 0) await pixelInfo(focusPixel);
      await updateSelection();
      renderCommunity();
      draw();
      tick();
      await refreshAuctionSummary();
      if (previous !== season || (!galleryLoaded && season > 1n))
        await loadGallery(true);
      else if (
        forceGallery ||
        (!busy && !$("gallery").contains(document.activeElement))
      )
        await loadGallery(true);
    } catch (e) {
      live = false;
      $("connection").textContent =
        "Connection interrupted · showing last loaded state";
      status(
        "Live refresh failed: " + error(e) + " Use Refresh to try again.",
        true,
      );
      throw e;
    } finally {
      controls();
    }
  })();
  try {
    await refreshing;
  } finally {
    refreshing = undefined;
  }
}
button("refresh").onclick = () =>
  void run(async () => {
    if (!ready) await boot();
    else await refresh(true);
    await refreshHistory();
    status("Live state refreshed.");
  });
let timersStarted = false;
async function boot() {
  status("Verifying live contracts on Robinhood Chain…");
  const key = await verifyDeployment();
  imd0 = same(key.currency0, config.contracts.imd);
  const [colours, launch, unit] = await Promise.all([
    canvas.getPalette(),
    hook.launchTime(),
    hook.dropUnit(),
  ]);
  palette = colours.map(
    (n: bigint) => "#" + Number(n).toString(16).padStart(6, "0"),
  );
  launchTime = Number(launch);
  dropUnit = unit;
  ready = true;
  drawPalette();
  await refresh();
  status("The canvas is live. Pick a colour and make your mark.");
  void refreshHistory();
  if (!timersStarted) {
    timersStarted = true;
    setInterval(() => {
      if (!document.hidden && !busy)
        void refresh()
          .then(() => refreshHistory())
          .catch(() => {});
    }, 20000);
    setInterval(tick, 1000);
  }
}
for (const target of ["header-contracts", "footer-contracts"])
  $(target).replaceChildren(
    ...Object.entries(config.contracts).map(([name, address]) =>
      contractLink(
        address,
        (
          {
            hook: "PlaceHook",
            canvas: "Canvas",
            router: "PlaceRouter",
            token: "i/p token",
            imd: "IMD",
            poolManager: "PoolManager",
            seasons: "Seasons NFT",
          } as Record<string, string>
        )[name] + " ↗",
      ),
    ),
  );
drawPalette();
draw();
controls();
void boot().catch((e) => {
  ready = false;
  live = false;
  controls();
  status(
    "Unable to load the launch: " + error(e) + " Use Refresh to retry.",
    true,
  );
});
