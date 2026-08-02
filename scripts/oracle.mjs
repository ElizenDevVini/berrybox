// Pushes real TCGplayer market prices into CardOracle.
// Data source is tcgcsv.com, a daily mirror of TCGplayer's price dump (no auth).
// Run after deploy, re-run any time to refresh: node scripts/oracle.mjs
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const RPC = process.env.RPC ?? "http://localhost:8546";
const KEY = process.env.KEY ?? "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil 0, oracle owner
const addr = JSON.parse(readFileSync(new URL("../web/src/addresses.json", import.meta.url)));

// One Piece Card Game is TCGplayer category 68. Groups: 3188 Romance Dawn, 23213 Awakening of the New Era.
const CARDS = [
  { id: 1, slug: "luffy", group: 23213, productId: 530122 }, // OP05-119 SEC Monkey.D.Luffy (Alternate Art)
  { id: 2, slug: "shanks", group: 3188, productId: 454666 }, // OP01-120 SEC Shanks (Manga) (Alternate Art)
  { id: 3, slug: "zoro", group: 3188, productId: 453511 }, // OP01-025 SR Roronoa Zoro (Parallel)
  { id: 4, slug: "nami", group: 3188, productId: 454534 }, // OP01-016 R Nami
  { id: 5, slug: "sanji", group: 3188, productId: 454529 }, // OP01-013 R Sanji
  { id: 6, slug: "chopper", group: 3188, productId: 454533 }, // OP01-015 UC Tony Tony.Chopper
  { id: 7, slug: "usopp", group: 3188, productId: 454516 }, // OP01-004 R Usopp
  { id: 8, slug: "robin", group: 3188, productId: 454538 }, // OP01-017 R Nico Robin
];

const rowsByProduct = {};
for (const group of [...new Set(CARDS.map((c) => c.group))]) {
  const res = await fetch(`https://tcgcsv.com/tcgplayer/68/${group}/prices`, {
    headers: { "user-agent": "berrybox-oracle/1.0" },
  });
  if (!res.ok) throw new Error(`tcgcsv group ${group}: HTTP ${res.status}`);
  for (const row of (await res.json()).results) {
    (rowsByProduct[row.productId] ??= []).push(row);
  }
}

const ids = [];
const prices = [];
for (const c of CARDS) {
  const rows = rowsByProduct[c.productId] ?? [];
  const row = rows.find((r) => r.subTypeName === "Foil" && r.marketPrice) ?? rows.find((r) => r.marketPrice);
  if (!row) throw new Error(`no TCGplayer market price for ${c.slug} (product ${c.productId})`);
  ids.push(c.id);
  prices.push(Math.round(row.marketPrice * 1e6));
  console.log(`${c.slug}: $${row.marketPrice}`);
}

execSync(
  `cast send ${addr.oracle} "setPrices(uint16[],uint256[])" "[${ids}]" "[${prices}]" --rpc-url ${RPC} --private-key ${KEY}`,
  { stdio: "inherit" }
);
console.log("oracle updated");
