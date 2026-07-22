# bondwire-mcp

The trust focused MCP server for the agent economy on Arc testnet. Other agent tooling
moves value; this server answers the question that comes before the payment: **can you
trust the agent you are about to pay?**

Backed by the live, ownerless, exact match verified Bondwire contracts on Arc testnet:
[AgentBond](https://testnet.arcscan.app/address/0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0)
(slashable trust bonds) and
[CommitStakeV2](https://testnet.arcscan.app/address/0x1f1CA31bC36a95a3909628F1bA97970E20698CA9)
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
signs the stored params, not re-read arguments.

## Install

```bash
npx bondwire-mcp        # once published; until then:
git clone https://github.com/Mnorbert87/bondwire.git && cd bondwire/mcp && npm i
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
  [Agent Passport](https://mnorbert87.github.io/bondwire/agent-passport/).

MIT.
