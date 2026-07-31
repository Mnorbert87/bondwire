// Single source of truth: ../../sdk/bondwire.js.
//
// In the repo this file re-exports the sibling SDK directly, so there is exactly one copy to fix.
// In a PUBLISHED tarball the sibling does not exist, so `npm pack`'s `prepack` step vendors the
// SDK next to this file as `bondwire.impl.js` and the import below resolves to that instead.
// Without this, `npx bondwire-mcp` would install four files and die on the first import —
// measured before the fix: `npm pack --dry-run` = 4 files, 5.2 kB, no SDK.
let mod;
try {
  mod = await import("./bondwire.impl.js"); // packaged (vendored at prepack)
} catch {
  mod = await import("../../sdk/bondwire.js"); // in-repo development
}
export const { Bondwire, BONDWIRE } = mod;
