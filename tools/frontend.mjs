import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
const root = fileURLToPath(new URL("../", import.meta.url));
const home = process.env.IMD_TOOLCHAIN || "/tmp/imd-place-toolchain";
const require = createRequire(resolve(home, "package.json"));
const mode = process.argv[2] || "build";
if (mode === "typecheck") {
  await mkdir(home, { recursive: true });
  const config = resolve(home, "imd-tsconfig.json");
  await writeFile(
    config,
    JSON.stringify({
      extends: resolve(root, "web/tsconfig.json"),
      compilerOptions: {
        paths: {
          ethers: [resolve(home, "node_modules/ethers/lib.esm/index.d.ts")],
        },
      },
    }),
  );
  const result = spawnSync(
    process.execPath,
    [require.resolve("typescript/bin/tsc"), "--project", config],
    { stdio: "inherit" },
  );
  process.exit(result.status ?? 1);
}
if (mode === "test") {
  const result = spawnSync(
    process.execPath,
    [resolve(root, "web/interaction-tests.mjs")],
    { stdio: "inherit", env: { ...process.env, IMD_TOOLCHAIN: home } },
  );
  process.exit(result.status ?? 1);
}
const vite = await import(pathToFileURL(require.resolve("vite")));
const config = {
  configFile: false,
  root: resolve(root, "site"),
  base: "./",
  publicDir: resolve(root, "site/public"),
  resolve: {
    alias: { ethers: resolve(home, "node_modules/ethers/lib.esm/index.js") },
  },
  build: { outDir: resolve(root, "dist"), emptyOutDir: true, target: "es2022" },
  server: { host: "0.0.0.0" },
  preview: { host: "0.0.0.0", port: 4173, strictPort: true },
};
if (mode === "preview") {
  const server = await vite.preview(config);
  server.printUrls();
} else if (mode === "build") await vite.build(config);
else throw Error("Use build, typecheck, preview or test.");
