# bondwire-mcp

The trust focused MCP server for the agent economy on Arc testnet. Other agent tooling
moves value; this server answers the question that comes before the payment: **can you
trust the agent you are about to pay?**

Backed by the live, ownerless, source-verified Bondwire contracts on Arc testnet:
[AgentBond](https://testnet.arcscan.app/address/0x4383Ea48837eF7e60fC22BD67945BCBf0551702c)
(slashable trust bonds) and
[CommitStakeV2](https://testnet.arcscan.app/address/0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474)
(bonded verifier escrow, pay only on verified PASS).

## Tools

Read only (no key needed):

| Tool | What it answers |
|---|---|
| `bondwire_passport` | What is this agent's word worth in burnable USDC? Score, tier, slash history. |
| `bondwire_bond_status` | Bond breakdown: total, locked, free, escrow allowance. |
| `bondwire_commitment` | Full state of one escrowed commitment. |
| `bondwire_stats` | Live counters of the whole stack. |

Value moving (need `AGENT_PRIVATE_KEY`, an Arc **testnet** burner):

| Tool | What it does |
|---|---|
| `bondwire_commit_quote` | Quote a bonded escrow, including a live passport check on the verifier. Signs nothing. |
| `bondwire_commit_execute` | Signs exactly the quoted params. Requires `confirmed: true` + the `previewId`. |
| `bondwire_resolve` | Verifier posts the verdict its own bond stands behind. |
| `bondwire_finalize` | Settles a commitment after the challenge window. |

Every value moving tool follows **quote before execute**: the model must show the user a
preview and get a yes before anything signs. Previews expire after 10 minutes and execute
signs the stored params, not arguments read again.

## Install

```bash
npx bondwire-mcp        # once published; until then:
git clone https://github.com/Mnorbert87/bondwire.git
cd bondwire
npm install             # root: ethers. server.mjs imports ../sdk/bondwire.js, and Node
                        # resolves that file's own imports upward from sdk/, so a install
                        # inside mcp/ alone leaves it unresolved and the server exits.
cd mcp && npm i         # the MCP SDK and zod
```

Claude Desktop / any MCP client config:

```json
{
  "mcpServers": {
    "bondwire": {
      "command": "node",
      "args": ["/path/to/bondwire/mcp/server.mjs"],
      "env": { "AGENT_PRIVATE_KEY": "0x… testnet burner, optional for read only" }
    }
  }
}
```

## Notes

- Arc testnet only (chain 5042002, USDC is the gas token). Never point a mainnet key at this.
- The public Arc RPC rejects batched and concurrent JSON RPC; the vendored SDK handles both.
- The SDK underneath is [bondwire-sdk](../sdk/), same addresses, same math as the hosted
  [Agent Passport](https://bondwire.dev/agent-passport/).

MIT.
