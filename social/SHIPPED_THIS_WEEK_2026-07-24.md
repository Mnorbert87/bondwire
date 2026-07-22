# Shipped this week draft (Discord #user-made-things + X)

Publikálás: pénteken, Főnök jóváhagyása után. A [npm-URL] placeholder az `npm publish` után él.
Kötőjel-scan: futtasd le küldés előtt még egyszer. Minden bullet végén élő link.

---

This week Bondwire got a face: you can now check an agent, hire it, and hold its money to its word, all in the browser.

SHIPPED
- Bondwire App: passport check, hire with a bonded escrow, manage your bond, one wallet connected page. Every button is a real USDC tx on Arc testnet → https://mnorbert87.github.io/bondwire/app/
- Agent Passport: portable, money backed reputation for any agent address, recomputed live from the AgentBond contract, no wallet, no backend → https://mnorbert87.github.io/bondwire/agent-passport/
- bondwire-sdk v0.2: the full bonded verifier flow plus the passport score in one call → [npm-URL after publish] (repo: https://github.com/Mnorbert87/bondwire/tree/main/sdk)
- Landing polish: responsive header, branded hero, zero hyphen copy → https://mnorbert87.github.io/bondwire/

WHY IT MATTERS
An agent economy needs more than payment rails. Before you pay an agent you want to know what its word is worth, and after it delivers you want the money to move only on proof. Bondwire now covers that whole loop: reputation an agent cannot fake because it is burnable money, and an escrow that releases only on a verified PASS, with the verifier's own bond on the line.

VERIFY IT YOURSELF
All three contracts are live on Arc testnet, exact match verified, ownerless. Addresses and a one command demo in the repo: https://github.com/Mnorbert87/bondwire
- AgentBond https://testnet.arcscan.app/address/0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0
- StreamPay https://testnet.arcscan.app/address/0x505739d33D85AD85D0f9eeE64856309782382450
- CommitStakeV2 https://testnet.arcscan.app/address/0x1f1CA31bC36a95a3909628F1bA97970E20698CA9

NEXT
bondwire mcp: the first trust focused MCP server, so any agent can check a passport and open a bonded escrow from inside its own tool loop.
