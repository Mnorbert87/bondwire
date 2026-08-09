# Bondwire site gap analysis

> **Status, 2026-08-08.** Everything in section 2 below except the npm republish has since
> been fixed and is live on bondwire.dev. The findings are left in place unedited, because a
> list of what was wrong is worth more to a reader than a list of what was fixed, and because
> the fixes should be checked rather than believed. Verify anything here against the live
> site; where the site and this document disagree, the site is newer.
>
> | item | state on 2026-08-08 | how it was checked |
> |---|---|---|
> | B1 hero numbers | fixed | tiles render an em dash until the RPC answers; live read 20.00 / 8 / 4 / 0.96 |
> | B2 unlimited allowance, no address on /app/ | fixed | the page asks for an amount, defaulting to the bond actually held; six addresses shown before signing |
> | B3 buried proof | fixed | deck, judge path, architecture and the demo reachable from the landing page |
> | B4 phones | fixed | Chromium at 390px, nine pages, scrollWidth 390 on every one |
> | B5 orphan pages, stray comma | fixed | every wallet page has a way back; 25 comma placeholders replaced, live sweep finds none |
> | B6 head meta | fixed | canonical, icon, OG and theme-color on /app/ and /bonded-verifier/ |
> | B7 LICENSE, repo metadata | fixed | GitHub API reports MIT, a description, a homepage and eight topics |
> | B7 npm `bondwire-sdk@0.2.0` | fixed | 0.3.0 published and 0.2.0 deprecated 2026-08-09; a plain `npm i bondwire-sdk` resolves to 0.3.0, verified from an empty npm cache |
> | B8 ethers on a CDN | fixed | vendored; with esm.sh aborted at the network layer every page still reads the chain |
> | B9 empty wallet dead end | fixed | every wallet page links the faucet and states the chain id |
> | B10 x402 link, deck URLs | fixed | the CTA goes to /x402-demo/; no github.io left in deck.html |
>
> Found in the same pass and also fixed, none of them in the list below: /app/ reported
> "Commitment #?" after a successful escrow because its ABI carried the predecessor's event
> signature; /agent-bond/, /stream-pay/ and /commit-stake/ never handed back the id they had
> just created; /bonded-verifier/ labelled every status one position off the contract's enum;
> refused actions showed "missing revert data" because the Arc RPC omits revert reasons on a
> gas estimate.

Merged from six review lenses (hackathon judge, product design, web3 security, frontend engineering, legal ops, devrel), deduplicated, and re-measured against the live site on 2026-08-07.

Measurement method for the chain figures below: `eth_call` `balanceOf` on USDC `0x3600…0000` against `https://rpc.testnet.arc.network`, run directly, not read from a doc. Live pages fetched with `curl -H 'Cache-Control: no-cache' 'https://bondwire.dev/…?cb=<nonce>'`.

---

## 1. The honest verdict

A professional landing on bondwire.dev today sees a genuinely good looking site with real contracts behind it, a branded social card, a custom 404, a security policy and a contact block, which is already ahead of most hackathon submissions. But the four numbers at the very top of the page are a hardcoded snapshot that overstates the chain by 2.6x on bonded USDC and 47x on streaming USDC, and they render silently under a green dot that says "live", so the first thing a judge can check is the first thing that fails. And the deeper you click the thinner it gets: the main dApp asks for an unlimited slash allowance without ever showing a contract address, four wallet pages overflow their own viewport on a phone, and the strongest assets on the server (the demo video, JUDGES.md, the deck, the architecture diagram, the MCP server, the arcscan source verification) are either buried in the footer or linked from nowhere at all.

Nothing here is a rebuild. It is roughly five hours of work, and the top two items are under an hour.

---

## 2. Before the submission (Aug 9-10)

### B1. The hero numbers are wrong and lie loudly — 15 min, do this first
**submission-critical**

Measured live right now, by me:

| Hero claims | Chain says | Ratio |
|---|---|---|
| 52.03 USDC bonded | **20.00** | 2.6x over |
| 44.83 USDC in streams | **0.955** | 47x over |
| 16 obligations | 7 | 2.3x over |
| 20 streams opened | 4 | 5x over |

The overwrite path at `index.html:520-537` only fires if the RPC answers. `index.html:530` and `:543` swallow the failure with `catch (e) { /* keep static snapshot values */ }`, and the caption at `index.html:277` says "Live onchain figures from Arc testnet" either way. So on a throttled load a judge reads four false numbers under a blinking green dot, and a 30 second arcscan check falsifies all four. On a good load they watch the headline TVL animate *down* from 52.03 to 20.00 and streams from 20 to 4, which reads as "the stack got drained."

**Fix, two edits in `index.html`:**

1. Replace the hardcoded values at lines **272-275**, **291-292** and **304-305** with a neutral placeholder so a cold RPC can never render a false number as live:
   ```html
   <div class="stat"><b id="sBond">—</b><small>USDC bonded</small></div>
   <div class="stat"><b id="sObl">—</b><small>Obligations</small></div>
   <div class="stat"><b id="sStreams">—</b><small>Streams opened</small></div>
   <div class="stat"><b id="sFlow">—</b><small>USDC in streams</small></div>
   ```
2. Stop swallowing. In both catch blocks (`index.html:530`, `:543`) write the dash and flip the caption:
   ```js
   } catch (e) {
     setBoth(["sBond","sObl","sStreams","sFlow","pBondTvl","pBondObl","pStreamN","pStreamFlow"], "—");
     $("liveNote").textContent = "● The public Arc RPC did not answer on this load. Reload, or read the same numbers on arcscan.";
     $("liveNote").style.color = "var(--muted)";
   }
   ```
   Give the caption at line 277 `id="liveNote"` and change its default copy to:
   > ● Read live from Arc testnet on page load. A dash means the public RPC did not answer, reload or read the same numbers on arcscan.

Same class of drift at `index.html:365` ("4 seeded commitments"). Re-check it against CommitStakeV2 in the same pass.

---

### B2. /app/ asks for an unlimited slash allowance and never shows a contract address — 30 min
**submission-critical**

`/app/` is the main dApp and the page most likely to be clicked from a submission form. Verified: regex `0x[0-9a-fA-F]{40}` over everything in `app/index.html` before the `<script type="module">` block returns **zero matches**. Every sibling page does this right. Then `app/index.html:616` fires `ab.setSlashAllowance(ADDR.CommitStakeV2, ethers.MaxUint256)` with no confirm step, on a page that already has a "Preview, nothing is signed yet → Confirm and sign" gate for hiring.

MetaMask will show the user a raw `0x4383…` they have no way to check against anything on screen. That is the exact habit phishing relies on, on a page whose whole pitch is accountability.

**Fix:**

Paste this card into `app/index.html` directly under the header, above the hero, so it is visible before Connect is ever clicked:

```html
<div class="card">
  <h2>Contracts you will be signing against</h2>
  <div class="kv">
    <b>AgentBond</b><span><a class="mono" id="cAB" target="_blank" rel="noopener"></a></span>
    <b>StreamPay</b><span><a class="mono" id="cSP" target="_blank" rel="noopener"></a></span>
    <b>CommitStakeV2</b><span><a class="mono" id="cCS" target="_blank" rel="noopener"></a> · source verified on arcscan</span>
    <b>USDC (gas and value)</b><span class="mono">0x3600000000000000000000000000000000000000</span>
  </div>
  <p class="sub">Arc testnet only. The USDC here comes from a faucet and has no monetary value, nothing you sign on this page can cost you real money. Verify these addresses against the README at github.com/Mnorbert87/bondwire before you sign anything.</p>
</div>
```

and in the module script:

```js
for (const [id,k] of [["cAB","AgentBond"],["cSP","StreamPay"],["cCS","CommitStakeV2"]]) {
  const a = $(id); a.textContent = ADDR[k]; a.href = EXPLORER + "/address/" + ADDR[k];
}
```

Then route the `bAllowBtn` handler through the existing preview gate, showing the word **UNLIMITED** and the CommitStakeV2 address before it signs.

---

### B3. Surface the proof you already paid for — 60-90 min
**important** · merges five separate findings

Everything below is on the server, returns 200, and is linked from nowhere on the landing page. Verified by dumping every `href` in `index.html`.

| Asset | State |
|---|---|
| Demo video (`youtube.com/watch?v=QI-dMcepg-g`, 200) | linked **once**, in a footer contact column |
| `JUDGES.md` (10 KB, 200) | zero inbound links |
| `deck.html` and `BONDWIRE_DECK.pdf` (200) | zero inbound links |
| `architecture.png` (1.7 MB, 200) | zero inbound links, page has **zero `<img>` elements** |
| MCP server + JS SDK | the word "MCP" appears on **no** live page |
| arcscan exact-match source verification on all three contracts | landing page never says so |

Correction to one lens: the demo video **does** exist and **is** linked, in the footer. The gap is that it is at 95% scroll, not that it is missing.

**Fix, four edits in `index.html`:**

1. **Header actions** (`index.html:242-245`), put the two time-boxed entry points first:
   ```html
   <a class="back-link" href="https://www.youtube.com/watch?v=QI-dMcepg-g" target="_blank" rel="noopener" style="font-size:13px;color:var(--muted);text-decoration:none;border:1px solid var(--line);border-radius:999px;padding:9px 15px;background:var(--glass);">▶ Demo, 2 min</a>
   <a class="back-link" href="https://github.com/Mnorbert87/bondwire/blob/main/JUDGES.md" target="_blank" rel="noopener" style="font-size:13px;color:var(--muted);text-decoration:none;border:1px solid var(--line);border-radius:999px;padding:9px 15px;background:var(--glass);">For judges, 2 min</a>
   <a class="nav-cta" href="./app/">Open the app</a>
   ```
   (Point `JUDGES.md` at the GitHub blob URL, not at `bondwire.dev/JUDGES.md`. GitHub renders the markdown, your own domain serves it raw.)

2. **A band directly under the hero stat row**, ready to paste:
   > **Short on time?** [JUDGES.md](https://github.com/Mnorbert87/bondwire/blob/main/JUDGES.md) is four things you can click and verify yourself in two minutes: the two onchain burn transactions, the CCTP bridge legs, the ERC-8004 identities, and one command that runs the full test suite. Or [watch the two minute walkthrough](https://www.youtube.com/watch?v=QI-dMcepg-g).

3. **The architecture diagram**, inside the "How an autonomous agent uses both" section. Compress it first, 1.7 MB is a slow first paint on conference wifi, target under 250 KB:
   ```html
   <img src="./architecture.png" alt="One agent lifecycle: bond up, get hired, lock collateral, stream the pay, settle" loading="lazy" style="max-width:100%;border-radius:14px;border:1px solid var(--line)">
   ```

4. **A "Build on it" proof strip** above the existing address bar, reusing the `.addr-bar` pill styling so it costs no new CSS:
   ```html
   <div class="addr-bar rise d5">
     <a href="./deck.html">Pitch deck ↗</a>
     <a href="https://github.com/Mnorbert87/bondwire/tree/main/mcp" target="_blank" rel="noopener">MCP server ↗</a>
     <a href="https://github.com/Mnorbert87/bondwire/tree/main/sdk" target="_blank" rel="noopener">JavaScript SDK ↗</a>
     <a href="https://github.com/Mnorbert87/bondwire/blob/main/SECURITY_AUDIT.md" target="_blank" rel="noopener">Security audit ↗</a>
     <a href="https://github.com/Mnorbert87/bondwire/blob/main/THREAT_MODEL.md" target="_blank" rel="noopener">Threat model ↗</a>
   </div>
   ```

5. Append `<span class="badge-ok">✓ source verified</span>` to each of the three address rows in the footer chain block, with one caption:
   > All three contracts are Blockscout exact-match verified on arcscan. The source in the repo is the deployed bytecode, byte for byte.

**The MCP server deserves its own card in `#products`, positioned first**, because the track is literally "Best Agentic Economy Experience" and almost nobody else will ship one:

> **Drive the whole stack from an LLM agent, no UI.** An MCP server that exposes the passport read, the bonded escrow open and the settle path as agent tools. Every value moving tool is quote before execute, so nothing signs without an explicit confirmation.

And one line in the hero lead: *"Readable by a human, callable by an agent. Nothing here needs a wallet to read."*

---

### B4. Four wallet pages break on a phone — 45 min
**important**

Judges browse submissions on phones. Measured `document.scrollWidth` in headless Chromium at a 390px viewport:

| Page | scrollWidth | `@media` count in source |
|---|---|---|
| `/bonded-verifier/` | **504** | 0 |
| `/commit-stake/` | 413 | 0 |
| `/agent-bond/` | 396 | 0 |
| `/stream-pay/` | 392 | 0 |

Confirmed by grep: `agent-bond/index.html`, `stream-pay/index.html`, `commit-stake/index.html` and `bonded-verifier/index.html` contain **zero** media queries between them. On `/agent-bond/` and `/commit-stake/` the overflowing element is the Connect Wallet button itself, wrapped onto two lines with its right half off screen. On `/bonded-verifier/` the contract address runs off the edge mid-string.

**Fix.** Paste this before `</style>` in all four files:

```css
@media (max-width: 600px) {
  header { padding: 11px 14px; gap: 10px; flex-wrap: wrap; }
  header .net-badge, .brand small { display: none; }
  .wrap, .container, main { padding-left: 14px; padding-right: 14px; }
  button, .primary, #connectBtn, #connect { width: 100%; white-space: normal; }
  .grid2, .row, .kv { grid-template-columns: 1fr; flex-direction: column; align-items: stretch; }
  .mono { overflow-wrap: anywhere; }
}
```

Two wide tables are clipped with no way to reach the cut columns, and in both cases the lost column is the credibility column:
- `ledger/index.html:104` — the SLASHED column is off screen and **unreachable**, because `html`/`body` set `overflow-x:hidden` (lines 18, 20) and the table has no inner scroller.
- `commit-stake/index.html` — `#v2table` is 572px wide in a 390px viewport, "Slashed slice → §7a" is off the fold.

Wrap both:
```html
<div style="overflow-x:auto;-webkit-overflow-scrolling:touch;-webkit-mask-image:linear-gradient(90deg,#000 92%,transparent)"> … table … </div>
```

Verify by re-reading `document.scrollWidth` at 390px. It must equal 390. Do not eyeball a screenshot.

---

### B5. Orphan pages: no way home, no footer, and a stray comma where numbers go — 45 min
**important** · merges four findings

`/agent-bond/`, `/stream-pay/`, `/bonded-verifier/` each contain exactly two `<a>` tags on the live page and both are Google Fonts preconnects. `/commit-stake/` has one real link, an arcscan address. None of the four has a link home. `/bonded-verifier/` has **no `<footer>` element at all** and `/ledger/` has none either. These are the pages a judge deep-links from a demo video or a submission form, and once there they are stranded.

Worse, the pre-wallet empty state renders a literal comma as a value. Every visitor arrives disconnected, so this is what everyone sees first: on `/agent-bond/` the third hero stat tile reads `,` framed in a card like a real figure; `/bonded-verifier/` reads "your USDC ,". The source is a shared helper whose null branch returns `", "`, in six files, plus two hardcoded commas at `bonded-verifier/index.html:56-57`. This looks like an em dash placeholder that the no-hyphen copy sweep replaced with a comma. A rendering bug on a page that then asks you to approve a USDC spend is the worst possible first impression for a trust product.

**Fix, three passes:**

1. **Back link.** Add to the header of `agent-bond/`, `stream-pay/`, `commit-stake/`, `bonded-verifier/`:
   ```html
   <a href="../" class="back-link" style="font-size:13px;color:var(--muted);text-decoration:none;border:1px solid var(--line);border-radius:999px;padding:9px 15px;">← All dApps</a>
   ```

2. **Footer, ready to paste**, into `app/`, `agent-bond/`, `stream-pay/`, `commit-stake/`, `bonded-verifier/` (create the element) and `ledger/` (create the element):
   ```html
   <footer style="margin:40px 0 24px;font-size:12px;color:var(--muted);line-height:1.7;text-align:center">
     <a href="../">Bondwire</a> ·
     <a href="https://github.com/Mnorbert87/bondwire" target="_blank" rel="noopener">Source</a> ·
     <a href="mailto:cryptophantomhungary@gmail.com">Contact</a> ·
     <a href="mailto:cryptophantomhungary@gmail.com?subject=BONDWIRE%20SECURITY">Report a security issue</a><br>
     Arc testnet only. Testnet USDC has no monetary value and these contracts are unaudited. Do not connect a wallet that holds real assets.
   </footer>
   ```
   That last sentence currently appears on the two pages where nothing can happen (`/` and `/use-case/`) and on none of the five where a visitor is asked to sign.

3. **Kill the commas.** Replace the null branch in all six `short()` definitions (`index.html:441`, `commit-stake/index.html:485` and `:770`, `use-case/index.html:273`, `agent-bond/index.html:462`, `stream-pay/index.html:472`, `bonded-verifier/index.html:155`): `: ", "` → `: "not connected"`. Replace the two hardcoded commas at `bonded-verifier/index.html:56-57` with `<span class="muted">connect wallet</span>`, and the `,` placeholders at `:55-57` with `—`. Then load `/agent-bond/` and `/bonded-verifier/` disconnected and confirm no cell renders punctuation as its entire value.

---

### B6. Head meta on the two pages the sweep missed — 10 min
**important**

Seven pages got the full head block in commit `23b46ec`. Two did not. Measured live:

| Page | og | canonical | icon |
|---|---|---|---|
| `/` | 9 | 1 | 1 |
| `/agent-bond/`, `/stream-pay/`, `/commit-stake/`, `/agent-passport/`, `/use-case/`, `/ledger/` | 6 | 1 | 1 |
| **`/app/`** | **0** | **0** | **0** |
| **`/bonded-verifier/`** | **0** | **0** | **0** |

`/app/` is the strongest page on the site and the one most likely to be shared directly. Its tab shows a blank icon and its link unfurls as a naked URL.

**Fix.** Copy the head block from `index.html` into `app/index.html` and `bonded-verifier/index.html`, changing only the per-page title, description and `og:url`:

```html
<meta name="theme-color" content="#060912">
<meta name="color-scheme" content="dark">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="canonical" href="https://bondwire.dev/app/">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Bondwire">
<meta property="og:url" content="https://bondwire.dev/app/">
<meta property="og:title" content="Bondwire app, hire an agent you can actually verify">
<meta property="og:description" content="Read an agent's money backed credit score, post a bond, open a bonded escrow and stream the payment. Live on Arc testnet.">
<meta property="og:image" content="https://bondwire.dev/og.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="https://bondwire.dev/og.png">
```

While in the heads: `/agent-bond/`, `/stream-pay/` and `/commit-stake/` have `og:` tags but no `name="description"`, and their titles are thin. Fix both at once:

- `<title>AgentBond, slashable USDC bonds for AI agents | Bondwire</title>` — *"An AI agent posts a USDC bond as collateral behind its onchain reputation and grants protocols the right to lock and slash it. Live on Arc testnet, ownerless, no admin keys."*
- `<title>StreamPay, continuous USDC settlement by the second | Bondwire</title>` — *"Lock USDC into a stream that accrues to the recipient linearly by the second. Pay per inference, per API call, per second. Live on Arc testnet."*
- `<title>CommitStake, staked commitments with a bonded verifier | Bondwire</title>` — *"Stake USDC behind a goal, a bonded AI verifier confirms before the deadline or the stake is slashed. Surplus burns. Live on Arc testnet."*

Also add `<meta name="theme-color" content="#060912">` to every page. On a near-black site the mobile browser chrome currently stays light, so the top of the phone screen is a bright bar above a black page.

---

### B7. LICENSE, repo metadata, and the npm package that ships dead addresses — 20 min
**important** · merges three findings

Verified just now:
- `ls LICENSE*` in the repo root → no match. GitHub API reports `"license": null`. `README.md:458` claims "MIT licensed." Several hackathons, Encode included, require an OSI-approved license **file** as a submission condition, and an eligibility check looks at the sidebar badge, not at a sentence in a 35 KB README.
- GitHub API: `"description": null`, `"topics": []`, `"homepage": "https://mnorbert87.github.io/bondwire/"`. The single `GitHub ↗` link in the footer is the whole developer funnel and it lands on a repo with a blank sidebar, still advertising the pre-rebrand URL.
- **Resolved 2026-08-09:** `bondwire-sdk@0.3.0` is published and `0.2.0` is deprecated. `latest` → 0.3.0, confirmed from the registry `dist-tags` with a cache-busted request, and an install into an empty npm cache pulls 0.3.0 and reads `status: 'Released'` off the live chain. The paragraph below is the finding as it stood before that.
- `bondwire-sdk` on npm: latest is **0.2.0**, published 2026-07-22, and it hardcodes the **pre-redeploy** trio (`0xB9b4…f8e0`, `0x5057…2450`, `0x1f1C…8CA9`). The contracts were redeployed 2026-07-31. Anyone who runs `npm i bondwire-sdk` gets a client wired to dead contracts, and the failure is silent because the old contracts still exist and still accept calls. This is the one path a developer takes without reading the README first.

**Fix, three commands:**

```bash
# 1. LICENSE
cat > LICENSE <<'EOF'
MIT License

Copyright (c) 2026 <full legal name>
... standard MIT text ...
EOF

# 2. repo metadata
gh repo edit Mnorbert87/bondwire \
  --homepage https://bondwire.dev \
  --description "Onchain trust and settlement primitives for AI agents on Arc: slashable reputation bonds, per-second USDC streams, and a bonded verifier escrow. SDK and MCP server included." \
  --add-topic arc --add-topic circle --add-topic usdc --add-topic ai-agents \
  --add-topic mcp --add-topic ethers --add-topic escrow --add-topic stablecoin

# 3. npm, at minimum the deprecate
npm deprecate bondwire-sdk@0.2.0 "Pre-redeploy addresses (superseded 2026-07-31). Upgrade to 0.3.0."
```

Publishing 0.3.0 is better but the deprecate alone is the load-bearing part: a warning on install beats silent writes to dead contracts. Verify with `npm view bondwire-sdk`, then re-download the tarball and grep for `0x4383Ea`.

---

### B8. Vendor ethers, remove the single point of failure — 30 min
**important** · flagged by three lenses independently

All ten interactive pages do `import { ethers } from "https://esm.sh/ethers@6.13.4"` at module top level. If esm.sh is slow, blocked or having a bad minute during the judging window, every page renders its shell and then does nothing: no chain reads, no wallet connect, no error message. The dApp pages degrade to dashes, the landing page degrades to the wrong hardcoded numbers (B1). There is no preconnect, so the first chain read also waits on a cold DNS plus TLS handshake.

The security angle is real but secondary: SRI cannot be applied to a bare `import` specifier, and the module is the thing constructing the transactions the user signs. The operational angle is what matters in the next 48 hours.

**Fix:**
```bash
curl -o vendor/ethers-6.13.4.min.js 'https://esm.sh/ethers@6.13.4?bundle'
```
Commit it, then find-replace the specifier in all ten files: `./vendor/…` from `index.html`, `../vendor/…` from the subdirectories. Zero build stays zero build, GitHub Pages serves it, and "no backend, nothing to break" becomes a claim you can make honestly.

**Verify by actually breaking it**, not by reading the diff: open `/app/` with esm.sh blocked in devtools and confirm Connect still works. If the esm.sh bundle still reaches out for subpaths, take `dist/ethers.min.js` from the npm tarball instead.

---

### B9. A judge who connects a wallet dead-ends immediately — 20 min
**important**

The one judge in ten who installs MetaMask and clicks Connect on `/bonded-verifier/` lands on "Step 0 · Bond the verifier" with zero USDC and zero gas, and no instruction anywhere on the page for how to get either. That judge converts from interested to broken in fifteen seconds, which is worse than never connecting. Grep confirms only `/x402-demo/` mentions a faucet.

**Fix.** One line directly under the Connect wallet button on `/app/`, `/agent-bond/`, `/stream-pay/`, `/commit-stake/`, `/bonded-verifier/`:

```html
<p class="sub">New here? <button class="btn ghost" onclick="ethereum.request({method:'wallet_addEthereumChain',params:[{chainId:'0x4CEF52',chainName:'Arc Testnet',rpcUrls:['https://rpc.testnet.arc.network'],blockExplorerUrls:['https://testnet.arcscan.app'],nativeCurrency:{name:'USDC',symbol:'USDC',decimals:6}}]})">Add Arc Testnet</button> then get testnet USDC from the <a href="FAUCET_URL_FROM_X402_DEMO" target="_blank" rel="noopener">Arc faucet ↗</a>. Chain 5042002, USDC is the gas token.</p>
```

---

### B10. Two one-line corrections — 5 min
**important**

- **`index.html:328`** sends the x402 CTA to `https://github.com/Mnorbert87/bondwire/tree/main/x402-demo`, a raw file listing, when `https://bondwire.dev/x402-demo/` renders cleanly. Change the href to `./x402-demo/` and demote the GitHub link to a secondary "read the source" line. This is the demo that maps most directly to the agentic commerce theme both hackathons are judging.
- **`deck.html:136`, `:360-361`** still print `mnorbert87.github.io/bondwire`. Everything else in the repo already says `bondwire.dev` — I verified `README.md` has zero github.io references. Fix the three lines and regenerate `BONDWIRE_DECK.pdf` from the HTML, because the PDF is a rendered artifact and will otherwise keep showing the old URL. Same for `agents/aiden.json:13` and `agents/verifier.json:13` (already fixed in the working tree, just uncommitted) — but note the URI written **onchain** is a separate truth, so check `tokenURI` with `eth_call` and say in the README whether the onchain copy still points at github.io.

---

## 3. After the submission

Ordered by value, not by effort.

1. **Seed the ledger so the economy is not two rows.** The "public reputation explorer" currently renders exactly two addresses (one Flagged, one Established, both bonded at 10.00). The mechanism is correct but it makes the economy look like a unit test. Run a script that creates 6-10 agents spanning all four tiers, at least one Trusted with a bond ≥ 400 USDC so the bond-depth term is not near zero, and vary the bond sizes so the Bond column is not a wall of 10.00. Re-measure and correct the hero numbers in the same pass so the two never disagree again.

2. **Self-host Google Fonts.** This is the one item with real EU case law behind it: LG München I, 3 O 17493/20, 20 January 2022, awarded damages for exactly this, and it set off a wave of warning letters across DACH aimed at small sites. Eight of ten live pages hotlink `fonts.googleapis.com` and `fonts.gstatic.com`, transmitting the visitor's IP to Google before any consent exists. Download the woff2 files into `assets/fonts/`, write `assets/fonts.css` with `@font-face` blocks and `font-display: swap`, replace the three head lines in all ten files. Sweep mechanically, missing one file leaves the exposure intact: `grep -rln 'fonts.googleapis.com' --exclude-dir=node_modules .` must return nothing, then verify each page live with a cache-busted curl.

3. **Imprint page.** Under § 25 Mediengesetz an Austrian media owner must disclose who is behind a website, and the duty does not depend on making money. The reduced disclosure in § 25 Abs 5 fits this site exactly, so it is three lines, not a legal document. § 5 E-Commerce-Gesetz arguably does not bite yet (free, no ads, no paid tier, no lead capture) but applies in full the moment anything commercial appears. **One honest caveat:** § 25 wants a real geographic address, and a PO box is not accepted. If a home address is unacceptable the only clean options are an Austrian service address through a coworking or virtual office, or a registered business address. There is no free workaround, and inventing one would be worse than the current gap.

4. **Privacy note**, published only after item 2 so the fonts paragraph is true. The instinct that this site collects nothing is almost right, and the gap between "almost nothing" and "nothing" is what Article 13 GDPR asks you to write down: GitHub Pages logs IPs, the Arc RPC receives IPs plus the addresses being queried, and three pages keep one localStorage key each (`ab_addr`, `cs_addr`, `sp_tok`). There is genuinely no analytics, no cookies and no accounts — verified by grep for gtag, google-analytics, plausible, umami, matomo, posthog and clarity across all pages, zero hits — so the note reads as a strength rather than boilerplate.

5. **Warn on the contract-address override.** `agent-bond/index.html:461,591` and `commit-stake/index.html:484,597` persist a user-supplied contract address in localStorage forever, with no reset and no warning when off the canonical address. Now that a trusted-looking custom domain exists, the natural phishing script is "go to the real bondwire.dev, click Change, paste this address". Compare the active address to the default after `loadInfo()`, and when they differ inject a red banner with the official address and a `Reset to official` button that calls `localStorage.removeItem` and reloads. Lead the `prompt()` text with the danger, not the instruction.

6. **Publish `bondwire-sdk@0.3.0` and `bondwire-mcp`.** `mcp/README.md:44` documents `npx bondwire-mcp`, which errors because the name is unregistered. Publishing also reserves the name. Verify with `npm pack --dry-run` that `lib/bondwire.impl.js` is in the tarball. Then fix `sdk/README.md:20`, which tells developers the SDK is "not on npm (yet)" and steers them to clone-and-copy, while a stale package with the same name sits on the registry.

7. **README quickstart, TOC, changelog, tags.** "Run it locally" starts at `README.md:300` and the SDK integration at `:328`; a developer must scroll past deployments, architecture, the CommitStakeV2 mechanism essay, ERC-8004 identity, a design FAQ and the audit trail before finding one runnable command, with no TOC to tell them it exists. Insert a `## Quickstart` block right after the intro table with three fenced blocks (npm install plus the 4-line bond+stream snippet, the MCP client config JSON, the clone-and-run command) and a 6-item TOC. Restructure `CHANGELOG.md` under dated version headings so the 2026-07-31 address supersession is visible to someone who did not clone, and `git tag -a v0.3.0` so the npm version corresponds to a commit anyone can point at.

8. **CSP meta tag.** Sequence this *after* item 2 and B8 — with esm.sh and fonts.googleapis.com still in play you would have to allow them and the policy buys much less. Then add as the first element after `<meta charset>` on every page:
   ```html
   <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' https://rpc.testnet.arc.network; frame-ancestors 'none'; base-uri 'none'; form-action 'none'">
   ```
   `'unsafe-inline'` on script-src is unavoidable, every page's logic is an inline module. The value is in `connect-src`, `frame-ancestors` and `base-uri`. Test by actually clicking Connect on `/app/`, `/agent-bond/` and `/bonded-verifier/` with the console open, not by reading the meta tag. A CSP typo silently kills the demo.

9. **Contrast.** `--faint: #525d72` measures **3.00:1** on `#060912`, where normal-size text needs 4.5:1, and it is used for 9px to 13px text on seven pages — the "Live onchain figures" caption, the source attributions, the tier labels. Raise to about `#7b869c` (~5.2:1), still clearly secondary next to `--muted: #8c98af`. `bonded-verifier/index.html:9` uses `--muted:#64748b` at 3.73:1 and its white-on-blue Connect button measures 3.68:1.

10. **`/bonded-verifier/` palette.** It declares its own tokens (`--bg:#0a0e17`, `--card:#111827`, `--blue:#3b82f6`), declares `font-family:'Inter'` while never loading Inter, and has no aurora, no grain, no logo mark. It reads as a different codebase bolted onto a polished site. Minimum: set `--blue:#4da2ff`, the green button to `#4fd6a8`, and either load Inter or drop it from the declaration so the declared font matches the rendered one.

11. **Six identical CTAs, no primary action.** `index.html:322-350` stacks Use case, x402, Agent Passport, App, Bonded verifier and Ledger as six visually identical gradient pills with identical weight. A judge with three minutes picks whichever is first, which is the use-case essay, not the working app. Keep exactly one gradient `.nav-cta` (the `/app/` one), move it under the hero lead as "Try it live, no setup", and convert the other five into a three-column card grid under "Explore the stack". Partly addressed by B3's header change.

12. **Wallet-free path above the fold.** The best thing about this project is that Agent Passport and Ledger read live reputation with no wallet and no backend, and the words "No wallet" appear once, at 68% scroll. Add a hero ghost button `./agent-passport/?agent=0x2e36F4037E711e1d4c853BBCBF7F526B3714A08a` labelled "Read a live agent passport, no wallet", and make `/agent-passport/` auto-run the lookup when `?agent=` is present so the score renders on load rather than after a click. That address returns bond 10.00, 3 taken, 3 completed, 0 slashed, score 60, tier Established — a real, non-empty passport.

13. **Mobile flow diagram.** `index.html:164-165` sets `.flow-track{flex-wrap:nowrap;overflow-x:auto}` with no breakpoint. At 390px a visitor sees "1 Bond up → 2 Get hired" and half of step 3, with no visible scrollbar on iOS and no fade edge. The reasonable reading is that the flow has two steps, which loses the slash, the stream and the settle — the whole thesis. Stack it under 700px rather than hiding it, or at minimum add a right-edge mask so the cut is legible as "more to the right".

14. **Reduced motion.** Five infinite animations (`pulse` 13s, `spin` 60s, `float` 5s, `glow` 4s, `blink` 2s) with no `prefers-reduced-motion` block on any page. One paste covers it, and it correctly overrides `html{scroll-behavior:smooth}` too.

15. **Hyphen sweep in visible copy.** `/agent-bond/` says "reputation-backed agent credit" while `index.html:241` says "reputation backed", two clicks apart. Also "USDC-NATIVE", "on-chain", "bonded-verifier", "pay-per-inference". Review each hit rather than a blind sed — CSS property names and Solidity identifiers keep their hyphens — then diff the rendered pages to confirm the replacement actually executed.

16. **Smaller polish.** `/x402-demo/` renders in GitHub's default Jekyll theme with two `h1` elements and 2.71:1 code comments; add a branded `x402-demo/index.html`, but do **not** add `.nojekyll` unless `/cctp-demo/`, `/agent/`, `/sdk/` and `/mcp/` are handled the same way, they would all start 404ing. `agent-passport/index.html:148` has no label or `aria-label` on its only input, and its heading levels run 1, 2, 4, 3. Add a `_config.yml` line `url: https://bondwire.dev` so the Jekyll canonical stops emitting `http://`. Append a footer line to `x402-demo/README.md` so a footer sweep does not silently skip the one page that is generated, not handwritten.

---

## 4. Deliberately not doing

| Thing | Why not |
|---|---|
| HSTS header | `bondwire.dev` is **HSTS preloaded at the TLD level** — Google's `.dev` ships in every browser binary with `includeSubdomains`, which is strictly stronger than the header, and protects the first visit too. Adding it would spend deadline hours on something already superseded. |
| Cookie banner | The site sets zero cookies (verified: no `document.cookie`, no `Set-Cookie` from GitHub Pages or Google Fonts). The three localStorage keys are values the visitor typed or toggled, exempt under § 165 Abs 3 TKG. A banner would be a downgrade. |
| Terms of service | No contract with visitors, nothing is sold, no consumer law applies. The one-sentence testnet warning in B5 does more real work than a page of boilerplate and does not invite anyone to read fine print during a demo. |
| Putting the burn transactions on the landing page | They are already on `/commit-stake/` as clickable arcscan anchors, twice each, plus a live-read "USDC BURNED (§7A SURPLUS)" tile. Six-plus proof links on the landing page would be worse design, not better. |
| Changing "two primitives" to "three" | Deliberate taxonomy, consistent across `index.html:381`, `README.md:17`/`:93`/`:97` and `deck.html:195`: CommitStakeV2 is the composed app layer, not a third primitive. Changing it would introduce a real inconsistency across five canonical locations. |
| og:image, favicon, robots.txt, sitemap.xml, custom 404, security.txt, contact block | All already shipped in commit `23b46ec` and verified live: `/og.png` is a real 2400x1260 PNG, `/.well-known/security.txt` returns 200 with the contact, `/404.html` is a branded page with four recovery links, the footer carries a three-column contact block. Only the two-page gap in B6 remains. |
| Rewriting `README.md` to `bondwire.dev` | Already done. `grep -c mnorbert87.github.io README.md` returns 0, verified both locally and on `raw.githubusercontent.com`. Only `deck.html` and the two agent JSONs are left (B10). |
| `.nojekyll` | Would 404 `/x402-demo/`, `/cctp-demo/`, `/agent/`, `/sdk/` and `/mcp/`, which are all served as rendered README pages today. |
| A `/demo/` index page | Returns 404, but it is the branded 404 and nothing on the site links to it. Only the README's directory tree mentions `demo/`. |
| European Accessibility Act compliance work | Does not reach a solo microenterprise publishing a non-commercial demo. The contrast fix in item 9 is worth doing on readability grounds alone, not on compliance grounds. |
