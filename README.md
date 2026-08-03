# berrybox

Provably fair trading card blind boxes, priced by a Uniswap v4 hook.

A box is a fixed set of cards whose full contents are committed on-chain at load. Contents are public, draw order is not. Sealed packs are an ERC-20 you buy by swapping native ETH through a v4 pool. The hook replaces the AMM curve with an EV curve: pack price equals the expected value of the remaining box contents times a premium, converted to wei at the oracle's ETH/USD rate. When someone pulls a chase card, every remaining pack reprices in the same block. Packs can also be sold back to the hook at EV minus a spread, so sealed product stays liquid.

The box maps to real One Piece TCG singles priced from TCGplayer market data. Local demo only. The card game and its images belong to Bandai/Shueisha, do not ship this commercially.

## How it works

- `BoxHook.sol` is a custom-curve v4 hook on a native-ETH/PACK pool. The pool has no LP liquidity. The hook is the sole counterparty, holding unsold pack inventory and the ETH float as ERC-6909 claims. Buys are exact-output only, sells exact-input only, so packs stay whole-numbered. Buy price is EV x 1.15, buyback is EV x 0.90, both quoted in wei. The spread is house revenue. Buying needs no token approval since payment is native ETH.
- `Booster.sol` is the pack token plus the box manifest. `open()` burns a pack and commits, `reveal()` draws a card one block later from the remaining manifest, without replacement.
- `CardVault.sol` is one ERC-721 per physical card in custody. `redeem()` burns and emits a shipment request. Custody is simulated here.
- `CardOracle.sol` is a pushed price feed: USD per card design plus an ETH/USD rate. `scripts/oracle.mjs` fills it with real TCGplayer market prices for the actual singles (via tcgcsv.com, a daily mirror of TCGplayer's price dump) and the Coinbase ETH spot price. The demo box maps to real cards: OP01-120 SEC Manga Shanks, OP05-119 SEC alt-art Luffy, OP01-025 SR parallel Zoro, plus five OP-01 commons.

EV per pack = sum of oracle prices of unopened cards / unopened count. Every remaining card backs exactly one outstanding pack, so this is the exact expected value of any single draw.

## Run it

Needs foundry and node.

```
anvil --port 8546 --disable-code-size-limit
forge script script/Deploy.s.sol --rpc-url http://localhost:8546 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast --disable-code-size-limit
cd web && npm install && npm run dev
```

Then push real card prices into the oracle (re-run any time to refresh):

```
node scripts/oracle.mjs
```

Open http://localhost:5173. The app signs with anvil account 0, no wallet extension needed. Deploy writes contract addresses to `web/src/addresses.json`.

`forge test` covers the EV pricing, buyback, commit-reveal opening, repricing after a pull, and rejection of USDC-specified swaps and external LPs.

## Honest limitations

- Randomness is blockhash commit-reveal. A block producer can influence it, and an expired commit can be re-armed for a re-roll. Production needs VRF.
- The buyback float starts at zero. Sell-backs only work after sales revenue exists.
- The oracle is owner-pushed from TCGplayer daily data. Production needs a signed feed with staleness checks, and intraday data for the grails.
- PoolManager is deployed without the code size limit for local convenience.

## Card images

`web/public/cards/` holds the official TCGplayer product images for the real singles. Bandai distributes most alt-art card images only with a SAMPLE watermark; every card database (TCGplayer, Bandai's own site, Limitless) shows the same files, so the watermarked ones are used as-is. The pack wrapper is Higgsfield-generated.
