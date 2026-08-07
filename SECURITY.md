# Security policy

Bondwire is a set of onchain contracts that custody USDC. This document says how to
report a problem and what is in scope.

## Reporting a vulnerability

Email **cryptophantomhungary@gmail.com** with `BONDWIRE SECURITY` in the subject, or open a
[GitHub issue](https://github.com/Mnorbert87/bondwire/issues) if the finding is not sensitive.

Please include what you would need if you were on the receiving end: the contract address and
chain, the function and input that triggers it, and what an attacker gains. A failing test or a
transaction hash is worth more than a description.

You will get an acknowledgement. This is a solo project, so a same-day reply is likely but not
promised. Nothing here is a bug bounty, there is no payout, and there is no legal agreement
behind this document.

Do not disclose publicly before the contracts are fixed or the report is declined.

## Scope

In scope, the four contracts deployed on Arc testnet:

| Contract | Address |
| --- | --- |
| AgentBond | [`0x4383Ea48837eF7e60fC22BD67945BCBf0551702c`](https://testnet.arcscan.app/address/0x4383Ea48837eF7e60fC22BD67945BCBf0551702c) |
| StreamPay | [`0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262`](https://testnet.arcscan.app/address/0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262) |
| CommitStakeV2 | [`0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474`](https://testnet.arcscan.app/address/0xf3457ABfd042Ef41bC22Ab20714D4D49cAaf1474) |
| CommitStake (v1) | see [`README.md`](README.md) |

Also in scope: the static frontend at [bondwire.dev](https://bondwire.dev) and the SDK and
MCP server in this repository.

Out of scope: the Arc testnet itself, the public RPC endpoint, third party explorers, and
anything that requires a user to hand over a private key.

## What is already known

These contracts are **testnet only**. They hold test USDC with no market value, they are
deployed ownerless with no admin key and no upgrade path, and they have not had a paid external
audit. What has been done instead is written down in the open, including the parts that did not
pass on the first attempt:

- [`THREAT_MODEL.md`](THREAT_MODEL.md), one adversary per section
- [`TEST_AUDIT.md`](TEST_AUDIT.md), an independent adversarial review of the test suite
- [`SECURITY_AUDIT.md`](SECURITY_AUDIT.md) and [`AUDIT_SUMMARY.md`](AUDIT_SUMMARY.md)

Do not put real money in these contracts.
