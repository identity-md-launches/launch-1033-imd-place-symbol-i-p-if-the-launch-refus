import {
  BrowserProvider,
  type Eip1193Provider,
  type JsonRpcSigner,
} from "ethers";
import { config } from "./chain";
export type Injected = Eip1193Provider & {
  on?: (name: string, fn: (value: unknown) => void) => void;
  removeListener?: (name: string, fn: (value: unknown) => void) => void;
  providers?: Injected[];
  isMetaMask?: boolean;
  isRabby?: boolean;
  isCoinbaseWallet?: boolean;
};
export type Wallet = { id: string; name: string; provider: Injected };
declare global {
  interface Window {
    ethereum?: Injected;
  }
}
const discovered = new Map<string, Wallet>();
let chosen: Injected | undefined;
let changed = () => {};
const listener = () => changed();
export function discover(
  update: (wallets: Wallet[]) => void,
  onChanged: () => void,
) {
  changed = onChanged;
  const publish = () => update([...discovered.values()]);
  window.addEventListener("eip6963:announceProvider", ((
    event: CustomEvent<{
      info: { uuid: string; name: string };
      provider: Injected;
    }>,
  ) => {
    const detail = event.detail;
    if (!detail?.info?.uuid || typeof detail.provider?.request !== "function")
      return;
    for (const [id, w] of discovered)
      if (w.provider === detail.provider) discovered.delete(id);
    discovered.set(detail.info.uuid, {
      id: detail.info.uuid,
      name: detail.info.name.slice(0, 80),
      provider: detail.provider,
    });
    publish();
  }) as EventListener);
  const injected =
    window.ethereum?.providers || (window.ethereum ? [window.ethereum] : []);
  injected.forEach((provider, i) =>
    discovered.set("injected-" + i, {
      id: "injected-" + i,
      name: provider.isRabby
        ? "Rabby"
        : provider.isCoinbaseWallet
          ? "Coinbase Wallet"
          : provider.isMetaMask
            ? "MetaMask"
            : "Browser wallet",
      provider,
    }),
  );
  publish();
  window.dispatchEvent(new Event("eip6963:requestProvider"));
}
export async function connectWallet(
  wallet: Wallet,
): Promise<{ signer: JsonRpcSigner; account: string }> {
  if (chosen !== wallet.provider) {
    chosen?.removeListener?.("accountsChanged", listener);
    chosen?.removeListener?.("chainChanged", listener);
    chosen = wallet.provider;
    chosen.on?.("accountsChanged", listener);
    chosen.on?.("chainChanged", listener);
  }
  if (
    BigInt((await chosen.request({ method: "eth_chainId" })) as string) !==
    BigInt(config.chainId)
  ) {
    try {
      await chosen.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: config.walletAddChain.chainId }],
      });
    } catch (error) {
      const e = error as {
        code: number;
        data?: { originalError?: { code: number } };
      };
      if (e.code !== 4902 && e.data?.originalError?.code !== 4902) throw e;
      await chosen.request({
        method: "wallet_addEthereumChain",
        params: [config.walletAddChain],
      });
      await chosen.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: config.walletAddChain.chainId }],
      });
    }
  }
  const provider = new BrowserProvider(chosen);
  await provider.send("eth_requestAccounts", []);
  if ((await provider.getNetwork()).chainId !== BigInt(config.chainId))
    throw Error("Switch your wallet to Robinhood Chain and reconnect.");
  const signer = await provider.getSigner();
  return { signer, account: await signer.getAddress() };
}
export async function assertWallet(account: string) {
  if (
    !chosen ||
    BigInt((await chosen.request({ method: "eth_chainId" })) as string) !==
      BigInt(config.chainId)
  )
    throw Error("Your wallet changed networks. Reconnect to Robinhood Chain.");
  const accounts = (await chosen.request({
    method: "eth_accounts",
  })) as string[];
  if (accounts[0]?.toLowerCase() !== account.toLowerCase())
    throw Error(
      "Your wallet account changed. Reconnect and review this action again.",
    );
}
