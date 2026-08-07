# Domain migration audit — bondwire.dev (adversarial cold read)

**Date:** 2026-08-07 ~21:00Z. **HEAD:** `d8179a9` (Create CNAME). **CNAME:** `bondwire.dev`.
**Framing:** adversarial — the goal was to find at least one way the move to `bondwire.dev`
broke something a judge or a first visitor would notice, not to confirm it is fine.

## Methodology (what was actually run, not inferred from local files)

All liveness measured against the **live** origin with cache-busting, redirects inspected
explicitly:

```sh
# subpages, no redirect follow
curl -sS -o /dev/null -w "%{http_code} redir=%{redirect_url}" "https://bondwire.dev/<path>?cb=$RANDOM"
# old origin behaviour
curl ... "https://mnorbert87.github.io/bondwire/<path>?cb=$RANDOM"
# on-chain tokenURI, read from the chain then resolved
cast-equivalent eth_call tokenURI(471762|471763) on 0x8004A818…BD9e  →  URL
curl -sS -L -w "%{http_code} %{url_effective}" "<on-chain URL>"
# meta/og/favicon, footer, security.txt
curl ... | grep -ioE '<(meta|link)[^>]*(og:|canonical|icon)…>'
```

Live pages checked (all `?cb=$RANDOM`): `/`, `/app/`, `/agent-bond/`, `/stream-pay/`,
`/commit-stake/`, `/bonded-verifier/`, `/agent-passport/`, `/use-case/`, `/ledger/`,
`/x402-demo/`, `/cctp-demo/`, `/agent/`, `/sdk/`, `/mcp/`, `/demo/`, `/agents/aiden.json`,
`/agents/verifier.json`, `/deck.html`, `/index.html`, a random 404 path, `/favicon.ico`,
`/.well-known/security.txt`, `/security.txt`, `/robots.txt`, `/sitemap.xml`.

## What works (so the findings below are not "nothing migrated")

- Every dApp subpage returns **200** on `bondwire.dev`. Internal navigation in the served
  HTML uses **relative** links (grep for `mnorbert87.github.io` in the live `/`, `/app/`,
  `/use-case/`, `/bonded-verifier/` HTML returned **zero** hits), so page-to-page nav did not
  break.
- The old origin **301-redirects** to the new one (`/bondwire/app/` → `https://bondwire.dev/app/`),
  so previously-shared links still resolve.

---

## THREAD A — migration correctness (weighted)

### A1 [HIGH] The on-chain ERC-8004 tokenURI still points at `mnorbert87.github.io`, cross-domain

`eth_call tokenURI(471762)` on `0x8004A818…BD9e` returns
`https://mnorbert87.github.io/bondwire/agents/aiden.json`; `tokenURI(471763)` returns the
`verifier.json` equivalent. Measured behaviour today: `curl` no-redirect → **301** to
`https://bondwire.dev/agents/aiden.json`; with `-L` → **200**. So it only resolves **through a
cross-domain 301**. NFT/metadata indexers (arcscan's included) frequently do **not** follow
cross-domain redirects, and arcscan is already demonstrably a **stale-caching** fetcher (the
earlier round measured it serving pre-rebrand "Arc Agentic Stack" metadata while the live JSON
said Bondwire). The ERC-8004 identity is a beat the video and `JUDGES.md` §0.3 lean on; on a
judge's screen its metadata can render **stale or empty** after the move. It is also permanently
fragile: the on-chain identity now depends on the GitHub Pages `CNAME` redirect existing forever.
A correct fix is an on-chain `setAgentURI` pointing directly at `bondwire.dev` (a chain write —
out of scope for this read-only audit; flagged for Főnök).

### A2 [HIGH] Every judge-facing artifact advertises the OLD `github.io` URL, not `bondwire.dev`

The new domain is live but nothing that reaches a judge uses it. Hardcoded `mnorbert87.github.io`:

- `deck.html:136`, `deck.html:360`, `deck.html:361` — **the pitch deck**, and `deck.html` served
  from `bondwire.dev/deck.html` (200 today) still prints `mnorbert87.github.io/bondwire`.
- The **video end card** (measured earlier at t≈173 in the v11 cut) shows
  `mnorbert87.github.io/bondwire`, not `bondwire.dev`.
- `JUDGES.md:97`, `SHOWCASE_SUBMISSION.md:14`, `SUBMISSION_DOCUMENT.html:88`,
  `README.md:24-28` and `README.md:168-169`.
- SDK/MCP: `sdk/package.json:34`, `mcp/package.json:29`, `sdk/README.md:4-6,76,106`,
  `mcp/README.md:63`.

A judge either lands on `github.io` (silently redirected, never sees the real domain) or notices
the deck showing a `github.io` URL while a `bondwire.dev` exists — reads as half-migrated. Pick
**one** canonical URL and make every judge-facing surface agree.

### A3 [MED] The served metadata JSON points back at the old domain

`https://bondwire.dev/agents/aiden.json` → `properties.homepage` =
`https://mnorbert87.github.io/bondwire/use-case/` (`agents/aiden.json:13`); same in
`agents/verifier.json:13` (`…/commit-stake/#v2`). Even fetched from the new domain, the metadata
advertises the old one. (Note: `agents/aiden.json` and `verifier.json` are in the uncommitted set
— if a fix is in progress locally it is **not deployed**; the live JSON still has `github.io`.)

### A4 [MED] No favicon

`/favicon.ico` → **404**, and the `<head>` has no `<link rel="icon">`. Generic/broken tab icon;
on a brand-new domain it reads unfinished, and it is the icon a judge's bookmark/tab shows.

### A5 [MED] No Open Graph / Twitter / canonical meta on any page

The live `<head>` has only `<title>` and `<meta name="description">`. No `og:image`, `og:url`,
`twitter:card`, or `<link rel="canonical">`. Consequences: (a) sharing the `bondwire.dev` link —
exactly what a submission does on the Ignyte/Encode platform, X, Discord — yields a **bare,
image-less preview**; (b) with no canonical, `github.io` and `bondwire.dev` serve identical content
as **duplicate URLs**, and a crawler/social cache may pin the `github.io` one.

### A6 [LOW] Old-origin apex redirect drops to `http://`

`https://mnorbert87.github.io/bondwire/` → 301 → `http://bondwire.dev/` (not `https`). The
subpaths redirect to `https`; only the apex first hop is insecure before the domain upgrades it.

### A7 [INFO, not a break] `/demo/` → 404 on the web

`/demo/` is a source directory (`node demo/commerce-scenario.js`), not a linked web page; its 404
is expected. Listed so it is not mistaken for a regression. (`/x402-demo/`, `/cctp-demo/`, `/agent/`,
`/sdk/`, `/mcp/` all return 200.)

---

## THREAD B — professional missing list (prioritized)

### Needed before submission (Aug 9 / 10)

1. **One canonical demo URL across deck, video, README, JUDGES, SHOWCASE, on-chain metadata.**
   The mismatch in A2/A3 is the single most visible "unfinished" signal. If `bondwire.dev` is the
   submission's demo URL, the deck and video must say `bondwire.dev`.
2. **`og:image` + `og:url` + a favicon.** The submission link is *going to be embedded and
   shared*; a link with no preview card is the first impression a community/judge gets.
3. **A contact and a security-disclosure channel.** Measured: no `security.txt`, no
   `.well-known/security.txt`, no email, no "report an issue" link anywhere. For a protocol that
   moves USDC (and aims at mainnet), at minimum a `SECURITY.md` + a visible GitHub-issues/"contact"
   link in the footer. A judge asking "who do I tell if I find a bug" has no answer today.

### Can wait (post-submission / production)

4. **Legal footer (Terms / Privacy).** The footer is one line
   (`… testnet demo, not for production use`) — honest, but a real product landing needs T&C /
   privacy. Arguably optional for a hackathon.
5. **Trust/operator signals:** no About/team, no "who runs this", no Discord/community link in the
   footer (only GitHub). Fine for a demo, expected for a product.
6. **The dApp does not surface its own audit.** `/app/` labels `testnet` (8×) but has **no** link
   to `THREAT_MODEL.md` / `AUDIT_SUMMARY.md` / a risk note from the UI (`audit`, `risk-disclosure`,
   `contact` all absent). The whole submission's edge is the honest self-audit — a wallet-connecting
   user should see it one click from the dApp.
7. **`robots.txt` / `sitemap.xml`** — both 404; SEO polish, low priority.
8. **Custom 404 page** — a bad deep link returns the default GitHub Pages 404.

---

*Read-only audit. No contract deployed, no key used, no push. The repo's uncommitted changes were
not touched. Fixes that require an on-chain write (A1 `setAgentURI`) are flagged, not performed.*
