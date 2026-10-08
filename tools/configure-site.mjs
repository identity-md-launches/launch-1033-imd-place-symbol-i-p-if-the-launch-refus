import { readFile, writeFile } from 'node:fs/promises';
import { ethers } from '../site/vendor/ethers.min.js';

const [rpc, hookAddress, explorer='https://robinhoodchain.blockscout.com'] = process.argv.slice(2);
if (!rpc || !ethers.isAddress(hookAddress) || hookAddress===ethers.ZeroAddress) {
  throw Error('Usage: node tools/configure-site.mjs RPC_URL DEPLOYED_HOOK [EXPLORER_URL]');
}
const abi=JSON.parse(await readFile(new URL('../site/abi.json',import.meta.url),'utf8'));
const manifest=JSON.parse(await readFile(new URL('../launch.json',import.meta.url),'utf8'));
const same=(a,b)=>a.toLowerCase()===b.toLowerCase();
const provider=new ethers.JsonRpcProvider(rpc);
try {
if ((await provider.getNetwork()).chainId!==4663n) throw Error('Expected Robinhood chain 4663');
const hook=new ethers.Contract(hookAddress,abi.PlaceHook,provider);
if (!(await hook.initialized())) throw Error('Launch pool is not initialized');
const contracts={hook:ethers.getAddress(hookAddress)};
for (const name of ['canvas','router','token','imd','poolManager']) contracts[name]=await hook[name]();
const canvas=new ethers.Contract(contracts.canvas,abi.Canvas,provider);
contracts.seasons=await canvas.seasons();
for (const [name,address] of Object.entries(contracts)) {
  if (address===ethers.ZeroAddress || await provider.getCode(address)==='0x') throw Error(`No code at ${name}`);
}
if (!same(contracts.imd,manifest.pool.pairedCurrency)) throw Error('Paired currency differs from launch.json');
if ((BigInt(hookAddress)&16383n)!==8396n) throw Error('Hook address has incorrect permissions');
const imd=new ethers.Contract(contracts.imd,abi.PlaceToken,provider);
if(await imd.symbol()!=='IMD' || await imd.decimals()!==18n)throw Error('Unexpected IMD metadata');
const token=new ethers.Contract(contracts.token,abi.PlaceToken,provider);
if(await token.name()!==manifest.token.name || await token.symbol()!==manifest.token.symbol ||
   await token.decimals()!==BigInt(manifest.token.decimals) || await token.totalSupply()!==10n**27n) {
  throw Error('Launch token differs from launch.json');
}
const key=await hook.getPoolKey();
const currencies=[contracts.imd,contracts.token].sort((a,b)=>BigInt(a)<BigInt(b)?-1:1);
if(key.fee!==BigInt(manifest.pool.fee) || key.tickSpacing!==BigInt(manifest.pool.tickSpacing) ||
   !same(key.currency0,currencies[0]) || !same(key.currency1,currencies[1]) || !same(key.hooks,hookAddress)) {
  throw Error('Pool key differs from launch.json');
}
const router=new ethers.Contract(contracts.router,abi.PlaceRouter,provider);
const seasons=new ethers.Contract(contracts.seasons,abi.Seasons,provider);
if(!same(await canvas.hook(),hookAddress) || !same(await canvas.imd(),contracts.imd) ||
   !same(await router.hook(),hookAddress) || !same(await router.manager(),contracts.poolManager) ||
   !same(await seasons.canvas(),contracts.canvas)) throw Error('Invalid child contract relationships');
const config={chainId:4663,rpc,explorer:explorer.replace(/\/$/,''),contracts,verifiedAtBlock:await provider.getBlockNumber()};
await writeFile(new URL('../site/deployment.json',import.meta.url),JSON.stringify(config,null,2)+'\n');
console.log('Verified contract relationships and wrote site/deployment.json. Publish the complete site/ directory.');
} finally {
provider.destroy();
}
