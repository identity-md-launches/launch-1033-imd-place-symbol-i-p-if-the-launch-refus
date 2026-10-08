// Read-only mainnet verification. Temporary balances apply only to eth_call, never transactions.
import { readFile, writeFile } from "node:fs/promises";
import { ethers as e } from "../site/vendor/ethers.min.js";
const json = async (path) =>
  JSON.parse(await readFile(new URL(path, import.meta.url), "utf8"));
const config = await json("../site/launch-config.json"),
  abis = await json("../site/abi.json");
const provider = new e.JsonRpcProvider(config.rpc, undefined, {
  cacheTimeout: -1,
  batchMaxCount: 10,
});
const canonical = (x) =>
  Array.isArray(x)
    ? x.map(canonical)
    : x && typeof x === "object"
      ? Object.fromEntries(
          Object.keys(x)
            .sort()
            .map((k) => [k, canonical(x[k])]),
        )
      : x;
const report = {
  checkedAt: new Date().toISOString(),
  rpc: config.rpc,
  sourceCommit: config.sourceCommit,
  abiHashes: {},
  runtimeCode: {},
  checks: [],
};
function check(condition, label) {
  if (!condition) throw Error(label);
  report.checks.push(label);
}
try {
  check(
    (await provider.getNetwork()).chainId === BigInt(config.chainId),
    "RPC chain ID is 4663",
  );
  const block = await provider.getBlock("latest"),
    tag = e.toQuantity(block.number);
  const echoed = await provider.send("eth_getBlockByNumber", [tag, false]);
  check(
    Number(BigInt(echoed.number)) === block.number,
    "Generated block parameter round-trips to the requested decimal block",
  );
  report.block = {
    number: block.number,
    hash: block.hash,
    timestamp: block.timestamp,
  };
  for (const [name, hash] of Object.entries(config.abiHashes)) {
    const actual = e
      .keccak256(e.toUtf8Bytes(JSON.stringify(canonical(abis[name]))))
      .slice(2);
    check(actual === hash, name + " canonical ABI matches deployment");
    report.abiHashes[name] = actual;
  }
  const contract = (name) =>
    new e.Contract(
      config.contracts[name],
      abis[
        {
          hook: "PlaceHook",
          canvas: "Canvas",
          router: "PlaceRouter",
          seasons: "Seasons",
          token: "PlaceToken",
          imd: "PlaceToken",
        }[name]
      ],
      provider,
    );
  const hook = contract("hook"),
    canvas = contract("canvas"),
    router = contract("router");
  for (const name of ["canvas", "router", "imd", "token", "poolManager"])
    check(
      (await hook[name]()).toLowerCase() ===
        config.contracts[name].toLowerCase(),
      `hook.${name} verifies configured address`,
    );
  check(
    (await canvas.seasons()).toLowerCase() ===
      config.contracts.seasons.toLowerCase(),
    "canvas.seasons verifies configured address",
  );
  for (const [name, address] of Object.entries(config.contracts)) {
    const code = await provider.getCode(address, block.number);
    check(code !== "0x", name + " has deployed code");
    report.runtimeCode[name] = {
      address,
      keccak256: e.keccak256(code),
      bytes: e.getBytes(code).length,
    };
    const contractName = {
      hook: "PlaceHook",
      canvas: "Canvas",
      router: "PlaceRouter",
      seasons: "Seasons",
      token: "PlaceToken",
    }[name];
    if (contractName && process.env.IMD_FORGE_OUT) {
      const artifact = JSON.parse(
        await readFile(
          `${process.env.IMD_FORGE_OUT}/${contractName}.sol/${contractName}.json`,
        ),
      );
      const expected = e.getBytes(artifact.deployedBytecode.object),
        actual = e.getBytes(code);
      for (const refs of Object.values(
        artifact.deployedBytecode.immutableReferences || {},
      ))
        for (const ref of refs) {
          expected.fill(0, ref.start, ref.start + ref.length);
          actual.fill(0, ref.start, ref.start + ref.length);
        }
      check(
        e.hexlify(actual) === e.hexlify(expected),
        contractName +
          " runtime matches compiled source outside immutable fields",
      );
      report.runtimeCode[name].compiledMatch = true;
    }
  }
  const call = { blockTag: block.number };
  const [season, start, pixelPrice, colours, fee, dropUnit] = await Promise.all(
    [
      canvas.currentSeason(call),
      canvas.seasonStart(call),
      canvas.price(0, call),
      canvas.coloursOf(1, call),
      hook.feeBps(call),
      hook.dropUnit(call),
    ],
  );
  check(
    e.getBytes(colours).length === 4096,
    "Live Canvas returns 4096 colour bytes",
  );
  report.canvas = {
    season: String(season),
    bytes: e.getBytes(colours).length,
    painted: e.getBytes(colours).filter((x) => x !== 255).length,
    pixel: 0,
    repaintPrice: String(pixelPrice),
    seasonStart: Number(start),
    seasonEnd: Number(start) + 604800,
    seasonEndISO: new Date((Number(start) + 604800) * 1000).toISOString(),
    hookFeeBps: String(fee),
  };
  const amount = e.parseUnits("1", 18),
    caller = config.contracts.router,
    coder = e.AbiCoder.defaultAbiCoder(),
    map = (a, s) => e.keccak256(coder.encode(["address", "uint256"], [a, s]));
  const overrides = {
    [config.contracts.imd]: {
      stateDiff: {
        [map(caller, config.storage.imd.balance)]: e.toBeHex(amount, 32),
        [map(
          config.contracts.router,
          BigInt(map(caller, config.storage.imd.allowance)),
        )]: e.toBeHex(amount, 32),
      },
    },
  };
  const imd = contract("imd");
  for (const [method, args] of [
    ["balanceOf", [caller]],
    ["allowance", [caller, config.contracts.router]],
  ]) {
    const result = await provider.send("eth_call", [
      { to: imd.target, data: imd.interface.encodeFunctionData(method, args) },
      tag,
      overrides,
    ]);
    check(
      imd.interface.decodeFunctionResult(method, result)[0] === amount,
      method + " verifies temporary quote storage override",
    );
  }
  const key = await hook.getPoolKey(),
    limit =
      key.currency0.toLowerCase() === config.contracts.imd.toLowerCase()
        ? 4295128740n
        : 1461446703485210103287273052203988822378723970341n;
  const result = await provider.send("eth_call", [
    {
      from: caller,
      to: router.target,
      data: router.interface.encodeFunctionData("swap", [
        true,
        true,
        amount,
        1n,
        limit,
        block.timestamp + 300,
      ]),
    },
    tag,
    overrides,
  ]);
  const [spent, received] = router.interface.decodeFunctionResult(
    "swap",
    result,
  );
  check(received > 0n, "PlaceRouter buy simulation returns a nonzero quote");
  report.buyQuote = {
    method:
      "eth_call PlaceRouter.swap, exact input, temporary IMD balance and allowance override",
    simulationCaller: caller,
    inputIMD: format(amount),
    spentIMD: format(spent),
    receivedIP: format(received),
    paintDrops: String(spent / dropUnit),
    rawResult: result,
  };
  check(
    (await canvas.drops(caller, call)) === 0n,
    "Paint simulation caller has zero real paint",
  );
  let reverted = false;
  try {
    await provider.call({
      from: caller,
      to: canvas.target,
      data: canvas.interface.encodeFunctionData("paintWithLimit", [
        [0],
        [4],
        pixelPrice,
      ]),
      blockTag: block.number,
    });
  } catch (error) {
    const parsed = canvas.interface.parseError(error.data);
    check(
      parsed?.name === "InsufficientPaint",
      "Underfunded paint eth_call returns InsufficientPaint",
    );
    report.paintError = {
      selector: error.data,
      name: parsed.name,
      message:
        "Not enough paint. Buy i/p to earn drops, or select fewer pixels.",
    };
    reverted = true;
  }
  check(reverted, "Underfunded paint did not succeed");
  report.transactionsSent = 0;
  report.limitations = [
    "Quote uses verified eth_call funding and approval overrides. It does not establish that a visitor has enough balance or allowance.",
    "No wallet was funded and no signed transaction was broadcast.",
  ];
  await writeFile(
    new URL("../docs/validation/mainnet-verification.json", import.meta.url),
    JSON.stringify(report, null, 2) + "\n",
  );
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  console.error(error.shortMessage || error.message);
  process.exitCode = 1;
} finally {
  provider.destroy();
}
function format(n) {
  return e.formatUnits(n, 18);
}
