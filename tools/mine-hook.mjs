import { readFile } from 'node:fs/promises';
import { ethers } from '../site/vendor/ethers.min.js';

const [create2Deployer, poolManager, token, factory, start='0'] = process.argv.slice(2);
for (const a of [create2Deployer,poolManager,token,factory]) if (!ethers.isAddress(a) || a===ethers.ZeroAddress) {
  throw Error('Usage: node tools/mine-hook.mjs CREATE2_DEPLOYER POOL_MANAGER LAUNCH_TOKEN LAUNCH_FACTORY [START_SALT]');
}
const artifact=JSON.parse(await readFile(new URL('../out/PlaceHook.sol/PlaceHook.json',import.meta.url),'utf8'));
const constructor=ethers.AbiCoder.defaultAbiCoder().encode(['address','address','address'],[poolManager,token,factory]);
const creationCode=ethers.concat([artifact.bytecode.object,constructor]);
const hash=ethers.keccak256(creationCode);
for (let i=BigInt(start);;i++) {
  const salt=ethers.zeroPadValue(ethers.toBeHex(i),32);
  const address=ethers.getCreate2Address(create2Deployer,salt,hash);
  if ((BigInt(address)&16383n)===8396n) {
    console.log(JSON.stringify({salt,address,flags:8396,initCodeHash:hash,constructorArgs:[poolManager,token,factory]},null,2)); break;
  }
}
