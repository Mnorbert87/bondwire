// Deduplicated 2026-07-25: the MCP server and the SDK shared two byte-identical 475-line
// copies of this module, so every fix had to be applied twice (and drifted). This file is
// now a thin re-export of the single source of truth in the sibling `sdk/` package.
// mcp/server.mjs imports `{ Bondwire, BONDWIRE }` from here unchanged.
export * from "../../sdk/bondwire.js";
