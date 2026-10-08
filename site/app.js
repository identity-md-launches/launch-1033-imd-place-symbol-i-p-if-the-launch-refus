import { ethers } from './vendor/ethers.min.js';

const $ = id => document.getElementById(id);
const board = $('canvas'), ctx = board.getContext('2d');
const names = ['Ink','White','Silver','Slate','Red','Orange','Yellow','Lime','Teal','Cyan','Blue','Indigo','Violet','Pink','Brown','Peach'];
let palette = ['181425','ffffff','c0cbdc','5a6988','ff0044','ff8426','ffd635','63c74d','009e8f','22d3ee','0099db','3e52f5','8b46ff','f472b6','8f563b','ffccaa'].map(c=>'#'+c);
let pixels = new Uint8Array(4096).fill(255), selected = new Map(), colour = 4, focusPixel = -1;
let config, abi, provider, signer, account, hook, canvas, seasons, router, imd, key;
let currentSeason = 0n, seasonStart = 0, chainTime = 0, syncTime = 0, decimal = 18;
let owners = [], zoom = 1, pan = [0,0], mode = 'select', pointer, busy = false, quote;
let galleryFloor = 0, galleryRequest = 0, refreshing = false;
const short = a => a.slice(0,6)+'…'+a.slice(-4);
const same = (a,b) => a?.toLowerCase() === b?.toLowerCase();
const format = (n, places=4) => {
  const [whole, frac=''] = ethers.formatUnits(n,decimal).split('.');
  return whole+(frac.slice(0,places).replace(/0+$/,'') ? '.'+frac.slice(0,places).replace(/0+$/,'') : '');
};
function status(message, error=false) { $('notice').textContent=message; $('notice').classList.toggle('error',error); }
function node(tag, text, className) { const e=document.createElement(tag); if(text!==undefined)e.textContent=text; if(className)e.className=className; return e; }
function contractLink(address, label) { const a=node('a',label); a.href=config.explorer+'/address/'+address; a.target='_blank'; a.rel='noopener'; return a; }
function safeError(e) { return e.shortMessage || e.reason || e.message || 'The transaction could not complete.'; }
function controls() {
  $('submit-paint').disabled=!config || !account || !selected.size || busy;
  $('quote').disabled=!config || !account || busy;
  $('buy').disabled=!quote || !account || busy;
  $('claim').disabled=!config || !account || busy;
  $('withdraw-refund').disabled=!config || !account || busy;
  $('connect').disabled=busy;
}
async function action(fn) {
  if(busy)return; busy=true; controls();
  try { await fn(); } catch(e) { status(safeError(e),true); }
  finally { busy=false; controls(); }
}
async function ensureWallet() {
  if(!window.ethereum)throw Error('Open this page in a wallet browser or install an Ethereum wallet.');
  if(!config)throw Error('The launch addresses have not been published yet.');
  const chain=await window.ethereum.request({method:'eth_chainId'});
  if(BigInt(chain)!==4663n) {
    try { await window.ethereum.request({method:'wallet_switchEthereumChain',params:[{chainId:'0x1237'}]}); }
    catch(e) {
      if(e.code!==4902)throw e;
      await window.ethereum.request({method:'wallet_addEthereumChain',params:[{chainId:'0x1237',chainName:'Robinhood Chain',nativeCurrency:{name:'Ether',symbol:'ETH',decimals:18},rpcUrls:[config.rpc],blockExplorerUrls:[config.explorer]}]});
    }
  }
  const walletProvider=new ethers.BrowserProvider(window.ethereum);
  await walletProvider.send('eth_requestAccounts',[]);
  signer=await walletProvider.getSigner(); account=await signer.getAddress();
  if((await walletProvider.getNetwork()).chainId!==4663n)throw Error('Switch to Robinhood Chain to continue.');
  $('connect').textContent=short(account);
  return signer;
}
async function send(contract, method, args=[]) {
  await ensureWallet();
  const tx=await contract.connect(signer)[method](...args);
  status('Submitted '+short(tx.hash)+' · waiting for confirmation…');
  const receipt=await tx.wait(); if(receipt.status!==1)throw Error('Transaction reverted.');
  status('Confirmed. Your canvas is up to date.');
  return receipt;
}
async function approve(token,spender,amount) {
  if(await token.allowance(account,spender)<amount) {
    status('Approve exactly '+format(amount)+' IMD in your wallet.');
    await send(token,'approve',[spender,amount]);
  }
}
function draw() {
  ctx.clearRect(0,0,1024,1024);
  for(let i=0;i<4096;i++) {
    const x=i%64,y=Math.floor(i/64),c=selected.has(i)?selected.get(i):pixels[i];
    ctx.fillStyle=c<16?palette[c]:((x+y)%2?'#1a1a23':'#16161e'); ctx.fillRect(x*16,y*16,16,16);
  }
  ctx.strokeStyle='#ffffff'; ctx.lineWidth=2;
  for(const id of selected.keys())ctx.strokeRect(id%64*16+2,Math.floor(id/64)*16+2,12,12);
  if(focusPixel>=0) {ctx.strokeStyle='#ffd635';ctx.lineWidth=3;ctx.strokeRect(focusPixel%64*16+1,Math.floor(focusPixel/64)*16+1,14,14);}
}
function setTransform(){board.style.transform=`translate(${pan[0]}px,${pan[1]}px) scale(${zoom})`; $('zoom').value=zoom;}
function drawPalette(){
  $('palette').replaceChildren(...palette.map((hex,i)=>{
    const b=node('button',undefined,'swatch');b.style.background=hex;b.title=names[i];b.setAttribute('aria-label',names[i]);b.setAttribute('aria-pressed',i===colour);
    b.onclick=()=>{colour=i;drawPalette();};return b;
  }));
}
async function updateSelection(){
  $('selection-count').textContent=selected.size+' pixels selected'; controls();
  if(config&&selected.size) {
    const ids=[...selected.keys()];
    const prices=await Promise.all(ids.map(id=>canvas.price(id)));
    if(ids.join(',')===[...selected.keys()].join(','))$('paint-cost').textContent=prices.reduce((a,b)=>a+b,0n).toString()+' drops';
  } else $('paint-cost').textContent=selected.size+' drops';
  draw();
}
async function updatePixelInfo(id){
  const season=currentSeason;
  const [p,price]=await Promise.all([canvas.pixels(season,id),canvas.price(id)]);
  if(id!==focusPixel||season!==currentSeason)return;
  const info=$('pixel-info');info.replaceChildren();
  const active=chainTime+Math.floor((Date.now()-syncTime)/1000)<Number(p.windowStart)+86400;
  info.append('Owner: ',same(p.owner,ethers.ZeroAddress)?node('span','unpainted'):contractLink(p.owner,short(p.owner)),node('br'),`${active?p.paints:0} paints in this window · ${price} drops now`);
}
async function choose(id){
  if(id<0||id>=4096||!Number.isInteger(id))return;
  focusPixel=id;$('coord-x').value=id%64;$('coord-y').value=Math.floor(id/64);
  if(selected.has(id)&&selected.get(id)===colour)selected.delete(id);
  else if(selected.size<50||selected.has(id))selected.set(id,colour);
  else status('A transaction can paint up to 50 pixels. Clear a selection to add another.');
  $('pixel-title').textContent=`Pixel (${id%64}, ${Math.floor(id/64)})`;
  if(canvas){
    await updatePixelInfo(id);
  }else $('pixel-info').textContent='Unpainted · 1 drop at launch';
  await updateSelection();
}
board.addEventListener('pointerdown',e=>{board.setPointerCapture(e.pointerId);pointer={id:e.pointerId,x:e.clientX,y:e.clientY,pan:[...pan]};});
board.addEventListener('pointermove',e=>{if(!pointer||e.pointerId!==pointer.id)return;if(mode==='pan'){pan=[pointer.pan[0]+e.clientX-pointer.x,pointer.pan[1]+e.clientY-pointer.y];setTransform();}});
board.addEventListener('pointerup',e=>{
  if(!pointer||e.pointerId!==pointer.id)return;
  if(mode==='select'&&Math.hypot(e.clientX-pointer.x,e.clientY-pointer.y)<10){const r=board.getBoundingClientRect();const x=Math.floor((e.clientX-r.left)/r.width*64),y=Math.floor((e.clientY-r.top)/r.height*64);if(x>=0&&x<64&&y>=0&&y<64)choose(y*64+x).catch(e=>status(safeError(e),true));}
  pointer=null;
});
board.addEventListener('pointercancel',()=>pointer=null);
$('viewport').addEventListener('wheel',e=>{e.preventDefault();zoom=Math.max(1,Math.min(8,zoom+(e.deltaY<0?.25:-.25)));setTransform();},{passive:false});
$('zoom').oninput=e=>{zoom=Number(e.target.value);setTransform();};
$('reset-view').onclick=()=>{zoom=1;pan=[0,0];setTransform();};
for(const m of ['paint','pan'])$(m+'-mode').onclick=()=>{mode=m==='paint'?'select':'pan';$('paint-mode').setAttribute('aria-pressed',m==='paint');$('pan-mode').setAttribute('aria-pressed',m==='pan');board.style.cursor=m==='pan'?'grab':'crosshair';};
$('choose-coordinate').onclick=()=>{const x=Number($('coord-x').value),y=Number($('coord-y').value);if(Number.isInteger(x)&&Number.isInteger(y)&&x>=0&&x<64&&y>=0&&y<64)choose(y*64+x).catch(e=>status(safeError(e),true));};
$('clear-selection').onclick=()=>{selected.clear();updateSelection();};
$('connect').onclick=()=>action(async()=>{await ensureWallet();await refresh(true);status('Wallet connected on Robinhood Chain.');});
$('submit-paint').onclick=()=>action(async()=>{
  const ids=[...selected.keys()],colours=[...selected.values()];
  const prices=await Promise.all(ids.map(id=>canvas.price(id))),max=prices.reduce((a,b)=>a+b,0n);
  await send(canvas,'paintWithLimit',[ids,colours,max]);selected.clear();await refresh(true);await updateSelection();
});
$('claim').onclick=()=>action(async()=>{await send(canvas,'claim');await refresh(false);});
$('withdraw-refund').onclick=()=>action(async()=>{await send(seasons,'withdrawRefund');await refresh(false);});
$('end-season').onclick=()=>action(async()=>{
  if(currentSeason>1n&&!(await seasons.rolloverResolved(currentSeason-1n)))await send(seasons,'finalize',[currentSeason-1n]);
  await send(canvas,'endSeason');selected.clear();await refresh(true);await loadGallery(true);
});
const priceLimit=buy=>{const imd0=same(key.currency0,config.contracts.imd);return buy===imd0?4295128740n:1461446703485210103287273052203988822378723970341n;};
$('quote').onclick=()=>action(async()=>{
  await ensureWallet();const amount=ethers.parseUnits($('swap-amount').value,decimal);if(amount<=0n)throw Error('Enter a positive IMD amount.');
  const slippage=Number($('slippage').value);if(!Number.isFinite(slippage)||slippage<0.1||slippage>10)throw Error('Choose slippage between 0.1% and 10%.');
  // The full swap is simulated from the connected wallet, including paint, fees and settlement.
  await approve(imd,config.contracts.router,amount);
  const block=await provider.getBlock('latest');
  const result=await router.connect(signer).swap.staticCall(true,true,amount,1,priceLimit(true),block.timestamp+300);
  const min=result[1]*BigInt(10000-Math.round(slippage*100))/10000n;
  if(min<=0n)throw Error('This amount is too small to quote.');
  quote={amount,min,deadline:block.timestamp+300,account};
  $('quote-info').textContent=`Receive about ${ethers.formatUnits(result[1],18)} i/p + ${amount/(10n**BigInt(decimal)/20n)} drops. Minimum ${ethers.formatUnits(min,18)} i/p. Quote valid for 5 minutes.`;
  status('Quote ready. Review the minimum output before buying.');
});
$('buy').onclick=()=>action(async()=>{await ensureWallet();if(!quote||!same(quote.account,account))throw Error('Get a fresh quote for this wallet.');const q=quote;quote=undefined;await send(router,'swap',[true,true,q.amount,q.min,priceLimit(true),q.deadline]);await refresh(true);});
for(const id of ['swap-amount','slippage'])$(id).oninput=()=>{quote=undefined;controls();};

async function readOwners(season){
  const all=[];
  for(let first=0;first<4096;first+=1024){const pages=await Promise.all([0,256,512,768].map(n=>canvas.pixelPage(season,first+n,256)));for(const page of pages)all.push(...page);}
  return all;
}
function renderCommunity(){
  const counts=new Map();owners.forEach(p=>{if(!same(p.owner,ethers.ZeroAddress))counts.set(p.owner,(counts.get(p.owner)||0)+1);});
  const ranks=[...counts.entries()].sort((a,b)=>b[1]-a[1]||a[0].localeCompare(b[0])).slice(0,12);
  $('leaderboard').replaceChildren(...ranks.map(([owner,count],i)=>{const li=node('li');li.append(contractLink(owner,`${String(i+1).padStart(2,'0')}  ${short(owner)}`),node('b',String(count)));return li;}));
  if(!ranks.length)$('leaderboard').append(node('li','The canvas is ready for its first painter.','muted'));
  const mine=owners.map((p,i)=>same(p.owner,account)?i:-1).filter(i=>i>=0);
  $('my-count').textContent=mine.length+' pixels held';
  $('my-pixels').replaceChildren(...mine.map(id=>{const b=node('button',`(${id%64},${Math.floor(id/64)})`);b.onclick=()=>{choose(id).catch(e=>status(safeError(e),true));$('play').scrollIntoView();};return b;}));
  if(!mine.length)$('my-pixels').append(node('p',account?'Your next pixel is waiting.':'Connect your wallet to find your place.','muted'));
}
function tick(){
  if(!currentSeason)return;
  const remaining=Math.max(0,seasonStart+604800-chainTime-Math.floor((Date.now()-syncTime)/1000));
  const d=Math.floor(remaining/86400),h=Math.floor(remaining/3600)%24,m=Math.floor(remaining/60)%60;
  $('timer').textContent=remaining?`${d}d ${String(h).padStart(2,'0')}h ${String(m).padStart(2,'0')}m`:'Ready to freeze';
  $('end-season').disabled=remaining>0||busy;
  $('season-state').textContent=remaining?'Until this canvas becomes a one-of-one.':'Anyone can close the season and start the next.';
}
async function refresh(withOwners=false){
  if(!config)return;
  // Preserve a post-transaction ownership refresh even when a polling read is in flight.
  if(refreshing){await refreshing;return refresh(withOwners);}
  const pending=refreshData(withOwners);refreshing=pending;
  try{await pending;}finally{refreshing=false;}
}
async function refreshData(withOwners){
    const [id,start,block,total,pot,paid,fee]=await Promise.all([canvas.currentSeason(),canvas.seasonStart(),provider.getBlock('latest'),canvas.totalPaid(),canvas.seasonPot(),seasons.totalPaid(),hook.feeBps()]);
    const changed=id!==currentSeason;currentSeason=id;seasonStart=Number(start);chainTime=block.timestamp;syncTime=Date.now();
    if(changed){selected.clear();withOwners=true;}
    const [cs,s]=await Promise.all([canvas.coloursOf(id),canvas.stats(id)]);pixels=ethers.getBytes(cs);
    $('season-label').textContent='SEASON '+id;$('occupied').textContent=s.occupied+' / 4096 pixels';$('total-paints').textContent=s.paints+' paints';
    $('total-paid').textContent=format(total+paid)+' IMD';$('pot').textContent=format(pot)+' IMD';$('connection').textContent='LIVE · BLOCK '+block.number;
    $('fee-info').textContent=`Hook fee now ${Number(fee)/100}%, plus the 1.25% pool fee. Paint is credited on total IMD spent, rounded down per buy.`;
    if(account){const [drops,earned,refund]=await Promise.all([canvas.drops(account),canvas.claimable(account),seasons.pendingRefunds(account)]);$('drops').textContent=drops.toString();$('refunds').textContent=format(refund)+' IMD';$('earnings').replaceChildren(document.createTextNode(format(earned)+' '),node('small','IMD'));}
    if(withOwners)owners=await readOwners(id);
    if(focusPixel>=0)await updatePixelInfo(focusPixel);
    renderCommunity();draw();tick();controls();
    if(changed)await loadGallery(true);
}
async function claimSeason(id){
  await ensureWallet();const all=await readOwners(id),bits=await Promise.all(Array.from({length:16},(_,i)=>seasons.claimedBitmap(id,i)));
  const ids=all.map((p,i)=>same(p.owner,account)&&!(bits[i>>8]&(1n<<BigInt(i&255)))?i:-1).filter(i=>i>=0);
  if(!ids.length)throw Error('No unclaimed final pixels for this wallet in this season.');
  for(let i=0;i<ids.length;i+=50)await send(seasons,'claim',[id,ids.slice(i,i+50)]);
  await refresh(false);await loadGallery(true);
}
async function auctionCard(id){
  const a=await seasons.auctions(id),card=node('article',undefined,'art-card');
  const image=node('img');image.alt='Frozen canvas of season '+id;
  try{const uri=await seasons.tokenURI(id),json=JSON.parse(atob(uri.split(',')[1]));if(/^data:image\/svg\+xml;base64,[A-Za-z0-9+/=]+$/.test(json.image))image.src=json.image;}catch{image.alt+=' · artwork temporarily unavailable';}
  card.append(image,node('h3','Season '+id),node('p',`${a.painters} painters · ${a.paints} paints · ${a.occupied} final pixels`),node('p',`Pot ${format(a.pot)} IMD · High bid ${format(a.highBid)} IMD`));
  if(!a.finalized&&Number(a.end)>chainTime&&a.occupied>0n){
    card.append(node('p','Auction closes '+new Date(Number(a.end)*1000).toLocaleString()));
    const input=node('input');input.type='text';input.inputMode='decimal';input.setAttribute('aria-label','Bid in IMD for season '+id);input.value=ethers.formatUnits(await seasons.minimumBid(id),decimal);
    const button=node('button','Approve & bid ↗');button.onclick=()=>action(async()=>{await ensureWallet();const amount=ethers.parseUnits(input.value,decimal);await approve(imd,config.contracts.seasons,amount);await send(seasons,'bid',[id,amount]);await refresh(false);await loadGallery(true);});card.append(input,button);
  }else if(!a.finalized){const button=node('button','Finalize auction ↗');button.disabled=Number(a.end)>chainTime;button.onclick=()=>action(async()=>{await send(seasons,'finalize',[id]);await refresh(false);await loadGallery(true);});card.append(button);}
  else {card.append(node('p',a.highBid>0n?'Sold · Artists can claim their final pixels.':a.occupied>0n?'No bids · Artwork awarded to the top painter.':'Blank canvas · Artwork retained in season escrow.'));
    if(a.highBid>0n){const button=node('button','Claim my season earnings ↗');button.onclick=()=>action(()=>claimSeason(id));card.append(button);}}
  const link=contractLink(config.contracts.seasons,'View NFT on explorer ↗');link.href=config.explorer+'/token/'+config.contracts.seasons+'/instance/'+id;const holder=node('p');holder.append(link);card.append(holder);
  return card;
}
async function loadGallery(reset=false){
  if(!config||currentSeason<2n)return;
  const request=++galleryRequest,start=reset?Number(currentSeason)-1:galleryFloor,cards=[];
  const end=Math.max(1,start-2);
  for(let id=start;id>=end;id--)cards.push(await auctionCard(BigInt(id)));
  if(request!==galleryRequest)return;
  if(reset)$('gallery').replaceChildren(...cards);else $('gallery').append(...cards);
  galleryFloor=end-1;$('more-seasons').hidden=galleryFloor<1;
}
$('more-seasons').onclick=()=>action(()=>loadGallery(false));
if(window.ethereum){
  const reset=()=>{account=undefined;signer=undefined;quote=undefined;$('connect').textContent='Connect wallet';$('drops').textContent='—';$('earnings').textContent='— IMD';$('refunds').textContent='— IMD';renderCommunity();controls();};
  window.ethereum.on?.('accountsChanged',reset);window.ethereum.on?.('chainChanged',reset);
}
async function boot(){
  drawPalette();draw();
  const response=await fetch('deployment.json',{cache:'no-store'});if(!response.ok)return;
  const candidate=await response.json();
  if(candidate.chainId!==4663||!candidate.rpc||!candidate.explorer||!candidate.contracts)throw Error('Invalid launch configuration.');
  for(const name of ['hook','canvas','seasons','router','token','imd','poolManager'])if(!ethers.isAddress(candidate.contracts[name])||same(candidate.contracts[name],ethers.ZeroAddress))throw Error('Launch address missing: '+name);
  abi=await (await fetch('abi.json')).json();provider=new ethers.JsonRpcProvider(candidate.rpc,undefined,{cacheTimeout:-1});
  if((await provider.getNetwork()).chainId!==4663n)throw Error('The configured RPC is on the wrong chain.');
  hook=new ethers.Contract(candidate.contracts.hook,abi.PlaceHook,provider);
  const links=await Promise.all([hook.canvas(),hook.router(),hook.token(),hook.imd(),hook.poolManager()]);
  for(const [i,name] of ['canvas','router','token','imd','poolManager'].entries())if(!same(links[i],candidate.contracts[name]))throw Error('Contract relationship mismatch: '+name);
  canvas=new ethers.Contract(candidate.contracts.canvas,abi.Canvas,provider);
  if(!same(await canvas.seasons(),candidate.contracts.seasons))throw Error('Season contract mismatch.');
  if(!(await hook.initialized()))throw Error('This launch pool has not been initialized.');
  seasons=new ethers.Contract(candidate.contracts.seasons,abi.Seasons,provider);router=new ethers.Contract(candidate.contracts.router,abi.PlaceRouter,provider);
  imd=new ethers.Contract(candidate.contracts.imd,abi.PlaceToken,provider);decimal=Number(await imd.decimals());key=await hook.getPoolKey();
  palette=(await canvas.getPalette()).map(c=>'#'+Number(c).toString(16).padStart(6,'0'));config=candidate;
  for(const target of ['header-contracts','footer-contracts'])$(target).replaceChildren(...Object.entries(config.contracts).map(([name,address])=>contractLink(address,name+' ↗')));
  drawPalette();await refresh(true);status('The canvas is live. Pick your pixels.');controls();
  setInterval(()=>refresh(false).catch(e=>status('Live refresh failed: '+safeError(e),true)),15000);
  setInterval(()=>refresh(true).catch(()=>{}),60000);
  setInterval(tick,1000);
}
boot().catch(e=>{config=undefined;controls();status('Unable to load the live canvas: '+safeError(e),true);});
