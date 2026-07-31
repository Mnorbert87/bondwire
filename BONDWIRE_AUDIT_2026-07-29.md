# Bondwire — Pre-Submission Audit, 2026-07-29

**Verdict: LEADHATÓ JAVÍTÁS UTÁN** (a javítás doksi-oldali: szám-szinkron + az „exact match" claim szűkítése a CommitStakeV2-re, ~20 perc; kód/lánc/secret oldalon nincs blokkoló).

*2026-07-29 frissítés: a 4. szekció verify-oszlopa és a teendő-lista 2. pontja kocka független bájt-diff mérése nyomán pontosítva — saját reprodukcióval megerősítve. Az első verzió „✅ verified" jelzése az AgentBond/StreamPay sorokban a Blockscout getabi-flagből jött, nem saját bájt-összehasonlításból; ez hiba volt, javítva.*

Auditor: Forge. Scope: friss klón a publikus repóról (`github.com/Mnorbert87/bondwire`, HEAD `6097737`), minden állítás saját futtatással/méréssel. Módszertani eltérés a feladathoz képest: a bekötött **evm MCP az Arc-ot (5042002) nem támogatja** („Unsupported network", újra kimérve ma) — az Arc-oldali mérések `cast` + Blockscout API-val készültek; a Base Sepolia CCTP tx viszont evm MCP-vel lett igazolva.

---

## 1. Secret-szivárgás — ✅ PASS

| Ellenőrzés | Eredmény | Parancs |
|---|---|---|
| Burner privkey a TELJES git historyban | ✅ 0 találat | `git grep <pk> $(git rev-list --all)` |
| `.env` / `.key` / `broadcast/` valaha commitolva | ✅ soha | `git log --all --diff-filter=A --name-only` |
| PEM/mnemonic a historyban | ✅ 0 | history-wide grep |
| Worktree kulcs-referenciák | ✅ mind env-alapú (`process.env`, `vm.env`, `.env.example`) | grep |
| 64-hex literálok | ✅ mind tx-hash / `bytes32(0)` / anvil-teszt-kulcs | osztályozva |

## 2. Kontraktus-tesztek FRISS KLÓNON — ✅ PASS (mind zöld, 0 skip)

| Projekt | Mért (friss klón) | README állít | JUDGES állít | Eltérés |
|---|---|---|---|---|
| agent-bond | **32 passed / 0 fail / 0 skip** (5 suite) | 29 | 32 | README stale |
| stream-pay | **25 / 0 / 0** (5 suite) | 25 | 25 | — |
| commit-stake | **28 / 0 / 0** (7 suite) | 25 | — | README stale |
| commit-stake-v2 | **102 / 0 / 0** (7 suite) | 79 | „79 tests / 6 suites" transcript | mindkettő stale |
| **Összesen** | **187** | tábla-összeg 158 | — | deck: „161" |

- foundry.toml mind a 4 projektben: fuzz `runs=10000`, invariant `runs=10000, depth=15, fail_on_revert=true` — a README „10,000 runs × depth 15" állítása **helytálló**.
- Halmos: `SymbolicSpec.t.sol`-ban pontosan **5** `check_` függvény — a „5 Halmos symbolic proofs" claim **helytálló**.
- Fix-branch claimek lefuttatva: `fix/agentbond-allowance-epoch` → **43/43** ✅; `fix/commitstake-param-bounds` → **109/109** ✅ (mindkettő pontosan a THREAT_MODEL/deck állítása).
- **Mutációs bizonyíték** („the tests bite"): a `totalEscrowed += received` könyvelés kikommentelése a create-útvonalon → **az 5 invariant-teszt MIND elbukik**. A védőháló élesben fog. (Forrás visszaállítva.)

## 3. Adversarialis review — ✅ PASS (dokumentált tudatos tradeoffokkal)

- **CEI + reentrancy**: minden pénzt mozgató external fn `nonReentrant`; state-átmenet a transfer ELŐTT (pl. `StreamPay.cancel` `status=Ended` az external call előtt, forrásból ellenőrizve). Az allowance-setterek guard nélküliek, de external-call-mentesek — rendben.
- **THREAT_MODEL §9 (USDC blacklist DoS)** — értékelésem: **valós kockázat, korrekt triage, tudatos tradeoff — elfogadható.** A §9a érvelés tartópontjait forrás-szinten ellenőriztem: `FEE_STREAM_STARTS_EARLY` gate (`CommitStakeV2.sol:361-365`) ✓, `slashVerifierExpired` permissionless és `deadline+1`-től hívható (`:598-601`) ✓, `StreamPay.cancel` 0-transfert kihagy (`if (toRecipient > 0)`) ✓ — tehát a „blacklistelt verifier NEM tudja megúszni a liveness-slasht" állítás igaz. A medium-besorolás (counterparty-selection risk, nem attacker-reachable griefing) védhető. Fixet nem deployolni az exact-match verify megőrzéséért: jogos döntés testnet-leadásnál, és a doksi őszintén kimondja.
- **THREAT_MODEL §10 (unbounded time params)** — ugyanez a kategória: valós, de fix-branch-en javítva+mérve (109/109), a nem-deployolás indoka dokumentált és igaz (1 karakter komment-módosítás töri a metadata-hasht — ezt a repo mérte, nem feltételezte).
- A SECURITY_AUDIT.md 2026-07-24-i „revoke nem végleges" korrekciója (release visszaadja az allowance-t) a forrásban visszaellenőrizve (`release()` → `slashAllowance += o.amount`) — a doksi állítása pontos.

## 4. On-chain igazolás — ✅ PASS

| Cím | Szerep | Bytecode | Verify (bájt-diff a MAI forrás buildje ellen) | Solvency (mért) |
|---|---|---|---|---|
| `0x1f1CA31b…98CA9` | CommitStakeV2 | ✅ non-empty | ✅ **VALÓDI exact-match**: metadata-farok 0 diff, 480 törzs-diff = a 3 immutable cím (path-leak sincs) | totalEscrowed **1.000000** == balance **1.000000** (pontos) |
| `0xB9b4d476…Bf8e0` | AgentBond | ✅ non-empty | ⚠️ explorer-verified (eth_bytecode_db), de **NEM reprodukálható a mai forrásból**: 71 diff = 10 törzs (immutable USDC-cím, normális) + **61 metadata-farok** → a lánc egy korábbi fordítási állapotot őriz. + metadata path-leak | Σ bond (state, minden valaha látott agent) **52.000000** ≤ balance **52.030849** (+0.030849) |
| `0x505739d3…82450` | StreamPay | ✅ non-empty | ⚠️ ugyanaz a minta: 71 diff = 10 törzs + **61 metadata-farok**, mai forrásból nem reprodukálható. + metadata path-leak | 213 stream (36 aktív) követelése **45.324444** ≤ balance **45.442940** (+0.118496) |
| `0xc307d928…9A9a2` | CommitStake V1 (frontend-default) | ✅ non-empty | — | — |

**Metadata-drift részletei (kocka független mérése + saját reprodukció, egyező eredmény):** a diagnózis kétlépcsős szabálya szerint a fordító-flag kizárva — ugyanaz a lokális toolchain a CommitStakeV2-re 0 metadata-diffet ad, tehát a flag-készlet jó; az AB/SP eltérés forrás/környezet-drift. A runtime-opcode a törzsben azonos (csak az immutable címek térnek el), tehát **funkcionálisan a repo kódja fut — ez NEM biztonsági hiba**, hanem reprodukálhatósági rés. Provenance-mérés: a drift a `425e278` komment-only commitnál RÉGEBBI (az az előtti build sem egyezik: 60/57 farok-diff), és az eredeti standalone `contracts/agent-bond` repo mai buildje már hosszabb bytecode-ot ad (12058 vs 10436) — a pontos deploy-forrás egyik repo mai állapotából sem állítható elő. A Blockscout a saját bytecode-DB-jéből (régi forrásra) mutatja verifiednek (`is_verified_via_eth_bytecode_db=true` az AB/SP-nél, false a CSV2-nél).

- `usdc()` getter mind a 3 fő kontraktuson = `0x36000…0000` (Arc natív USDC) ✓.
- **Mind a 13 doksi-hivatkozott tx igazolva**: 12 Arc-tx receipt `status=0x1` (blokk 46316107–47611348), 1 Base Sepolia CCTP `depositForBurn` (`0x6232b1…25d8`) `status=success` (evm MCP, blokk 42757497) — a doksi helyesen Base Sepoliaként címkézi.
- Solvency-többletek pozitív irányúak (a kontraktus többet tart, mint amennyivel tartozik) — direkt beküldött dust, nem hiány.

## 5. Over-claim vadászat — ⚠️ 1 FONTOS találat (stale számok, ALUL-állítás irányban)

**Nincs felfelé hazudó claim.** Amit találtam, az fordított: a doksik KEVESEBBET állítanak, mint ami van — de a „reprodukáld a saját gépeden" pitch miatt ez is javítandó:

| Doksi | Állít | Valóság | Súly |
|---|---|---|---|
| JUDGES.md:69 | „Ran 6 test suites: 79 tests passed" transcript | **7 suite, 102 teszt** — a zsűri MÁST lát, mint amit a doksi ígér | **FONTOS** |
| README.md:219-222 | 29 / 25 / 25 / 79 | 32 / 25 / 28 / 102 | FONTOS |
| deck.html + BONDWIRE_DECK.pdf | „161 Solidity tests" | 187 | FONTOS |
| SUBMISSION_DOCUMENT.html | „79-test suite" | 102 | FONTOS |
| SECURITY_AUDIT.md:18 | AgentBond invariant „256 runs · 128,000 calls" | jelen config 10,000 runs × depth 15 | KOZMETIKAI (régi futás száma) |

| deck címlap + JUDGES.md tábla | „Exact match verified" általánosan / ✅ Verified mindhárom sorban | **csak a CommitStakeV2 valódi exact-match**; AgentBond+StreamPay explorer-verified, de a mai forrásból NEM reprodukálható (metadata-drift, lásd 4. pont) — egy technikás zsűritag újrafordítva kettőnél eltérést kap | **FONTOS** |

Minden más mért claim stimmel: Halmos 5 ✓, 10k-invariant config ✓, fix-branch 43/109 ✓, exact-match a CommitStakeV2-n ✓, „three ownerless, verified" ✓, tx-linkek ✓, „not audited for production" disclaimer kint van ✓.

## 6. Frontend — ✅ PASS

- chainId `5042002` minden frontendben, idegen chainId sehol.
- A 3 fő cím konzisztensen ugyanaz minden HTML/JS-ben; a `commit-stake/index.html` V1-default címe (`0xc307…`) él a láncon.
- Élő URL-ek: repo-oldal + 4 al-dApp + 2 agent-JSON → mind **HTTP 200**.
- Headless konzol-teszt (Playwright, networkidle+3s, élő RPC-olvasásokkal): **mind az 5 oldal 0 console-error, 0 pageerror**.

## 7. Deck ↔ README konzisztencia — ⚠️ 1 FONTOS

- A deck ugyanazt a történetet mondja, mint a README (3 ownerless primitív, exact-match, Halmos, fix-branchek) — tartalmi ellentmondás nincs, csak a fenti szám-stale-ség.
- **`deck.html` és `BONDWIRE_DECK.pdf` UNTRACKED** — nincsenek a publikus repóban. Ha a leadás hivatkozik rájuk, commit+push kell (vagy külön feltöltés a platformra) — döntés kérdése, de most a zsűri nem éri el őket a repóból.

## 8. CI — ✅ PASS

HEAD `6097737`: `tests` ✅ success, `static-analysis` ✅ success, `pages build` ✅ success.

---

## Súlyozott teendő-lista

**BLOKKOLÓ:** nincs.

**FONTOS (leadás előtt javítandó, ~20 perc, csak doksi):**
1. Teszt-számok szinkronja: JUDGES.md transcript (79→102, 6→7 suite), README tábla (29→32, 25→28, 79→102), deck (161→187), SUBMISSION_DOCUMENT (79→102). A pitch gerince a „futtasd le magad" — a számoknak egyeznie KELL azzal, amit a zsűri lát.
2. **„Exact match" claim szűkítése**: a deck/JUDGES/README csak a **CommitStakeV2-re** állítsa az exact-matchet („recompile and compare, byte for byte"). Az AgentBond+StreamPay soraiban: „source-verified on the explorer; runtime body identical to this repo (only immutables differ); the metadata hash reflects an earlier compilation state" + 1 őszinte sor a miértről. Így a technikás zsűritag pontosan azt találja, amit ígérünk — a jelenlegi általános megfogalmazással kettőnél eltérést találna.
3. Deck-fájlok sorsa: commit a repóba VAGY explicit külön-feltöltés a leadási platformra.

**KOZMETIKAI (nem sürgős):**
4. SECURITY_AUDIT.md régi invariant-számok frissítése (256 runs → 10k×15).
5. AgentBond + StreamPay verified-metadata path-leak (`/Users/aisszisztens`): Blockscout-lock miatt ugyanazon a címen nem újra-verifikálható; low-sev info-disclosure, elfogadás ajánlott (CommitStakeV2 tiszta, a fő kirakat az).

*Minden szám ebben a jelentésben saját futtatásból/on-chain hívásból származik, 2026-07-29-én.*

---

## Fix-státusz (2026-07-29, commit `9033b25`, Főnök GO-jára)

- **FONTOS 1 (szám-szinkron): ✅ JAVÍTVA** — README tábla 32/25/28/102, JUDGES 102/7-suite transcript + felsorolás, deck 187 + 150k-invariant szöveg, SUBMISSION_DOCUMENT 102, commit-stake-v2/TEST_AUDIT 102 teljes bontással (39 unit + 21 adversarial + 23 exploit-audit + 6 fuzz + 5 invariant + 5 edge-mutation + 3 cold-audit). Minden szám kétszer futtatva (friss klón + munkafa), a bontás a `Ran N tests for` sorokból.
- **FONTOS 2 (exact-match szűkítés): ✅ JAVÍTVA** — a claim mindenhol a CommitStakeV2-re szűkítve (deck címlap-pill, JUDGES tábla + lábjegyzet, README megjegyzés, SUBMISSION_DOCUMENT lábjegyzet, SHOWCASE_SUBMISSION, mcp/README); az AgentBond/StreamPay soroknál az őszinte megfogalmazás (source-verified on explorer, runtime body identical, metadata reflects an earlier compilation state). A `social/` archívum szándékosan érintetlen (történeti poszt-másolat).
- **FONTOS 3 (deck a repóban): ✅ JAVÍTVA** — deck.html + BONDWIRE_DECK.pdf commitolva; előtte secret/path-scan tiszta (0 privkey, 0 `/Users/`, 0 username a PDF-ben is), a PDF a javított deck.html-ből újrarenderelve (10 oldal, 1280×720).
