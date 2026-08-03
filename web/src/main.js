import { createPublicClient, createWalletClient, http, parseAbi, formatUnits, decodeEventLog } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import addr from "./addresses.json";

const RPC = "http://localhost:8546";
// anvil account #0, local demo only
const account = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");

const chain = {
  id: 31337,
  name: "anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
};

const pub = createPublicClient({ chain, transport: http(RPC) });
const wallet = createWalletClient({ chain, transport: http(RPC), account });

// Each entry is a real One Piece TCG single; tcg is the TCGplayer product id the
// oracle tracks. Card images are the TCGplayer scans of the actual cards.
const CARDS = {
  1: { slug: "luffy", name: "Monkey.D.Luffy", set: "OP05-119", rarity: "SEC alt art", tcg: 530122, chase: true },
  2: { slug: "shanks", name: "Shanks", set: "OP01-120", rarity: "SEC manga", tcg: 454666, chase: true },
  3: { slug: "zoro", name: "Roronoa Zoro", set: "OP01-025", rarity: "SR parallel", tcg: 453511, chase: true },
  4: { slug: "nami", name: "Nami", set: "OP01-016", rarity: "R", tcg: 454534, chase: false },
  5: { slug: "sanji", name: "Sanji", set: "OP01-013", rarity: "R", tcg: 454529, chase: false },
  6: { slug: "chopper", name: "Tony Tony.Chopper", set: "OP01-015", rarity: "UC", tcg: 454533, chase: false },
  7: { slug: "usopp", name: "Usopp", set: "OP01-004", rarity: "R", tcg: 454516, chase: false },
  8: { slug: "robin", name: "Nico Robin", set: "OP01-017", rarity: "R", tcg: 454538, chase: false },
};

const hookAbi = parseAbi([
  "function quoteBuy(uint256) view returns (uint256)",
  "function quoteSell(uint256) view returns (uint256)",
  "function packInventory() view returns (uint256)",
  "function ethFloat() view returns (uint256)",
]);
const boosterAbi = parseAbi([
  "function evPerPack() view returns (uint256)",
  "function remainingCards() view returns (uint16[])",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function open(uint256)",
  "function reveal() returns (uint16[])",
  "event PackOpened(address indexed opener, uint16 indexed cardId, uint256 tokenId)",
]);
const oracleAbi = parseAbi([
  "function price(uint16) view returns (uint256)",
  "function ethUsd() view returns (uint256)",
]);
const vaultAbi = parseAbi([
  "function cardIdOf(uint256) view returns (uint16)",
  "function ownerOf(uint256) view returns (address)",
  "function redeem(uint256)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed id)",
]);
const routerAbi = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }",
  "struct TestSettings { bool takeClaims; bool settleUsingBurn; }",
  "function swap(PoolKey key, SwapParams params, TestSettings testSettings, bytes hookData) payable returns (int256)",
]);

const MIN_SQRT = 4295128739n + 1n;
const MAX_SQRT = 1461446703485210103287273052203988822378723970342n - 1n;
const MAX_UINT = 2n ** 256n - 1n;
const ZERO = "0x0000000000000000000000000000000000000000";

// native ETH is always currency0, the pack token currency1
const poolKey = { currency0: ZERO, currency1: addr.booster, fee: 0, tickSpacing: 60, hooks: addr.hook };

const $ = (id) => document.getElementById(id);
const usd = (v6) =>
  "$" + Number(formatUnits(v6, 6)).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const eth = (wei) =>
  "Ξ" + Number(formatUnits(wei, 18)).toLocaleString("en-US", { maximumFractionDigits: 4 });

let ethUsdRate = 0n;
const weiUsd = (wei) => usd((wei * ethUsdRate) / 10n ** 18n);

let busy = false;
const feedLines = [];

function feed(line, up = false) {
  feedLines.unshift({ line, up });
  feedLines.splice(6);
  $("feed").innerHTML = feedLines.map((f) => `<div class="${f.up ? "up" : ""}">${f.line}</div>`).join("");
}

async function swapPacks(count, isBuy) {
  const params = isBuy
    ? { zeroForOne: true, amountSpecified: count, sqrtPriceLimitX96: MIN_SQRT }
    : { zeroForOne: false, amountSpecified: -count, sqrtPriceLimitX96: MAX_SQRT };
  const h = await wallet.writeContract({
    address: addr.swapRouter,
    abi: routerAbi,
    functionName: "swap",
    args: [poolKey, params, { takeClaims: false, settleUsingBurn: false }, "0x"],
    value: isBuy ? await pub.readContract({ address: addr.hook, abi: hookAbi, functionName: "quoteBuy", args: [count] }) : 0n,
  });
  await pub.waitForTransactionReceipt({ hash: h });
}

async function buyPack() {
  const price = await pub.readContract({ address: addr.hook, abi: hookAbi, functionName: "quoteBuy", args: [1n] });
  await swapPacks(1n, true); // paying with native ETH, no approval needed
  feed(`bought pack @ ${eth(price)} (${weiUsd(price)})`);
}

async function sellPack() {
  const payout = await pub.readContract({ address: addr.hook, abi: hookAbi, functionName: "quoteSell", args: [1n] });
  const allowance = await pub.readContract({ address: addr.booster, abi: boosterAbi, functionName: "allowance", args: [account.address, addr.swapRouter] });
  if (allowance < MAX_UINT / 2n) {
    const h = await wallet.writeContract({ address: addr.booster, abi: boosterAbi, functionName: "approve", args: [addr.swapRouter, MAX_UINT] });
    await pub.waitForTransactionReceipt({ hash: h });
  }
  await swapPacks(1n, false);
  feed(`sold pack back @ ${eth(payout)} (${weiUsd(payout)})`);
}

async function openPack() {
  const evBefore = await pub.readContract({ address: addr.booster, abi: boosterAbi, functionName: "evPerPack" });
  let h = await wallet.writeContract({ address: addr.booster, abi: boosterAbi, functionName: "open", args: [1n] });
  await pub.waitForTransactionReceipt({ hash: h });
  h = await wallet.writeContract({ address: addr.booster, abi: boosterAbi, functionName: "reveal" });
  const receipt = await pub.waitForTransactionReceipt({ hash: h });

  let pulled = null;
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== addr.booster.toLowerCase()) continue;
    try {
      const ev = decodeEventLog({ abi: boosterAbi, data: log.data, topics: log.topics });
      if (ev.eventName === "PackOpened") pulled = Number(ev.args.cardId);
    } catch {}
  }
  if (pulled == null) throw new Error("reveal produced no PackOpened event");

  const evAfter = await pub.readContract({ address: addr.booster, abi: boosterAbi, functionName: "evPerPack" });
  const card = CARDS[pulled];
  feed(`pulled ${card.name} ${card.set} (${card.rarity})`, card.chase);
  if (evAfter !== evBefore) {
    const dir = evAfter < evBefore ? "down" : "up";
    feed(`pack EV ${dir}: ${usd(evBefore)} -> ${usd(evAfter)}`, true);
  }
  showReveal(card);
}

let revealStage = null; // { card } while waiting for the tear click

function showReveal(card) {
  const el = $("revealCard");
  revealStage = { card };
  el.className = "reveal-card stage-pack";
  el.innerHTML = `<img src="/pack.png" alt="sealed pack" /><h3>you got a pack</h3><p>click to tear it open</p>`;
  $("overlay").classList.add("show");
}

$("overlay").addEventListener("click", () => {
  if (revealStage) {
    const card = revealStage.card;
    revealStage = null;
    const el = $("revealCard");
    el.className = "reveal-card card-img" + (card.chase ? " chase" : "");
    el.innerHTML = `<img src="/cards/${card.slug}.jpg" alt="${card.name}" /><h3>${card.name}</h3><p>${card.set} · ${card.rarity} · click anywhere to close</p>`;
    return;
  }
  $("overlay").classList.remove("show");
});

async function myCards() {
  const logs = await pub.getLogs({
    address: addr.vault,
    event: vaultAbi.find((x) => x.type === "event" && x.name === "Transfer"),
    args: { to: account.address },
    fromBlock: 0n,
  });
  const owned = [];
  for (const log of logs) {
    const id = log.args.id;
    try {
      const owner = await pub.readContract({ address: addr.vault, abi: vaultAbi, functionName: "ownerOf", args: [id] });
      if (owner.toLowerCase() !== account.address.toLowerCase()) continue;
      const cardId = await pub.readContract({ address: addr.vault, abi: vaultAbi, functionName: "cardIdOf", args: [id] });
      owned.push({ tokenId: id, cardId: Number(cardId) });
    } catch (e) {
      // burned (redeemed) tokens revert ownerOf; anything else is a real bug
      if (!(e.message || "").includes("NOT_MINTED")) console.error("myCards", e);
    }
  }
  return owned;
}

async function redeemCard(tokenId) {
  const h = await wallet.writeContract({ address: addr.vault, abi: vaultAbi, functionName: "redeem", args: [BigInt(tokenId)] });
  await pub.waitForTransactionReceipt({ hash: h });
  feed(`redemption requested: token #${tokenId} ships to you`);
}

async function refresh() {
  const [remaining, ev, inventory, float_, ethBal, packBal, rate] = await Promise.all([
    pub.readContract({ address: addr.booster, abi: boosterAbi, functionName: "remainingCards" }),
    pub.readContract({ address: addr.booster, abi: boosterAbi, functionName: "evPerPack" }),
    pub.readContract({ address: addr.hook, abi: hookAbi, functionName: "packInventory" }),
    pub.readContract({ address: addr.hook, abi: hookAbi, functionName: "ethFloat" }),
    pub.getBalance({ address: account.address }),
    pub.readContract({ address: addr.booster, abi: boosterAbi, functionName: "balanceOf", args: [account.address] }),
    pub.readContract({ address: addr.oracle, abi: oracleAbi, functionName: "ethUsd" }),
  ]);
  ethUsdRate = rate;

  let buy = null, sell = null;
  try { buy = await pub.readContract({ address: addr.hook, abi: hookAbi, functionName: "quoteBuy", args: [1n] }); } catch {}
  try { sell = await pub.readContract({ address: addr.hook, abi: hookAbi, functionName: "quoteSell", args: [1n] }); } catch {}

  $("wallet").innerHTML = `${account.address.slice(0, 6)}…${account.address.slice(-4)}<br/>${eth(ethBal)} · ${packBal} pack${packBal === 1n ? "" : "s"}`;
  $("buyPrice").textContent = buy != null ? eth(buy) : "sold out";
  $("buyPriceUsd").textContent = buy != null ? weiUsd(buy) : "";
  $("sellPrice").textContent = sell != null ? `${eth(sell)} (${weiUsd(sell)})` : "no float yet";
  $("inventory").textContent = `${inventory} sealed`;
  $("buyBtn").disabled = busy || buy == null;
  $("openBtn").disabled = busy || packBal === 0n;
  $("sellBtn").disabled = busy || packBal === 0n || sell == null;
  $("heroPrice").textContent = buy != null ? `${eth(buy)} (${weiUsd(buy)})` : "sold out";
  $("heroBuyBtn").disabled = busy || buy == null;
  $("heroStrip").textContent =
    `EV per pack ${usd(ev)} · ${remaining.length} cards sealed · ETH ${usd(rate)} · house float ${eth(float_)}`;

  const sum = ev * BigInt(remaining.length);
  $("mathRows").innerHTML = [
    ["cards left in box", remaining.length],
    ["value left (TCGplayer market)", usd(sum)],
    ["EV per pack", usd(ev)],
    ["ETH / USD", usd(rate)],
    ["house float", `${eth(float_)} (${weiUsd(float_)})`],
  ].map(([k, v]) => `<tr><td>${k}</td><td>${v}</td></tr>`).join("");

  const counts = {};
  for (const id of remaining) counts[id] = (counts[id] || 0) + 1;
  const prices = {};
  await Promise.all(Object.keys(CARDS).map(async (id) => {
    prices[id] = await pub.readContract({ address: addr.oracle, abi: oracleAbi, functionName: "price", args: [Number(id)] });
  }));
  const tape = Object.entries(CARDS)
    .map(([id, c]) => `${c.name} ${c.set} ${usd(prices[id])}`)
    .join("   ·   ");
  $("tickerA").textContent = tape;
  $("tickerB").textContent = tape;

  $("manifest").innerHTML = Object.entries(CARDS).map(([id, c]) => {
    const n = counts[id] || 0;
    return `<div class="manifest-row ${n === 0 ? "gone" : ""}">
      <img class="thumb" src="/cards/${c.slug}.jpg" alt="" />
      <span class="name"><a href="https://www.tcgplayer.com/product/${c.tcg}" target="_blank" rel="noopener">${c.name}</a><span class="rarity ${c.chase ? "chase" : ""}">${c.set} · ${c.rarity}</span></span>
      <span class="count">x${n}</span>
      <span class="price">${usd(prices[id])}</span>
    </div>`;
  }).join("");

  const owned = await myCards();
  $("collection").innerHTML = owned.length
    ? owned.map((o) => {
        const c = CARDS[o.cardId];
        return `<div class="card-tile ${c.chase ? "chase" : ""}">
          <img src="/cards/${c.slug}.jpg" alt="${c.name}" />
          <div class="card-name">${c.name}</div>
          <div class="card-sub">#${o.tokenId} · ${c.set} · ${usd(prices[o.cardId])}</div>
          <button class="secondary" data-redeem="${o.tokenId}">redeem physical</button>
        </div>`;
      }).join("")
    : `<p class="note">nothing yet. buy a pack, tear it open.</p>`;
  document.querySelectorAll("[data-redeem]").forEach((b) =>
    b.addEventListener("click", () => act(() => redeemCard(b.dataset.redeem)))
  );
}

async function act(fn) {
  if (busy) return;
  busy = true;
  document.body.classList.add("busy");
  $("status").textContent = "tx pending…";
  refresh().catch(() => {});
  try {
    await fn();
  } catch (e) {
    console.error(e);
    feed(`error: ${(e.shortMessage || e.message || "tx failed").slice(0, 80)}`);
  }
  busy = false;
  document.body.classList.remove("busy");
  $("status").textContent = "";
  await refresh().catch(() => {});
}

$("buyBtn").addEventListener("click", () => act(buyPack));
$("heroBuyBtn").addEventListener("click", () => act(buyPack));
$("openBtn").addEventListener("click", () => act(openPack));
$("sellBtn").addEventListener("click", () => act(sellPack));

refresh().then(() => feed("connected to berrybox on anvil :8546"));
setInterval(() => { if (!busy) refresh().catch(() => {}); }, 4000);
