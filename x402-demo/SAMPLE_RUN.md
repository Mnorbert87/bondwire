# Sample run, verified on Arc Testnet (2026-08-05)

Real transcript of `./run.sh`, re-executed against the **live** StreamPay after the
2026-07-31 redeploy. Buyer agent `0x2e36…A08a`, x402 server (payee)
`0x0D09cA4F24CF66206f66DA1dc200d213327EEbDc`, StreamPay
`0x6C2Ae6f8Ba7c0259EABa8ef4048C8BFc68BAB262`, stream **#3**.

Every transaction below was checked by reading its receipt, not by trusting the script's own
output: all five report `status 1` and a `to` of `0x6C2Ae6f8…B262`.

```
[1/4] CALL — hitting http://localhost:4021/inference with no payment
   ← HTTP 402 Payment Required
     scheme=streampay asset=USDC payTo=0x0D09cA4F24CF66206f66DA1dc200d213327EEbDc

[2/4] PAY — opening a StreamPay stream: $0.300000 over 60s -> 0x0D09…EbDc
   ✓ createStream  gas ≈ $0.003650  /tx/0xf8a922407bd50546d5013fd7f31334ad4ad2e9504559f355b3ab11a21fd5d209
   stream #3 flowing at $0.005000/s

[3/4] CONSUME — paid calls (server settles per call from the stream)
   call 1: 200 — settled $0.060000  /tx/0x3842632fc1ae909774501aa6dc2b682ffcdce94eba23d06b0035ff4db8bb6c48
   call 2: 200 — settled $0.050000  /tx/0x71493d8e4c60fb6b66336a29577f295362b9f5e06353c086989bfd7ee50ccdb7
   call 3: 200 — settled $0.050000  /tx/0x8b62a397a84a66efee4e5e3c3caef1948c2acd0fb7c9b8769a136a5bc76b3ce5

[4/4] SETTLE — cancelling the stream to reclaim the unspent budget
   reclaimable (unused budget): $0.120000
   ✓ cancel stream #3  gas ≈ $0.002001  /tx/0x0b8130fb6e90941205b84b8615e5a35bdccd76e5c7de505c60bd2e1bed8aa475

✅ done. Paid per call, on-chain, autonomously.
   The 402→200 gate was bound to a live StreamPay settlement on Arc.
```

## Transaction index (Arc Testnet)

| Step | Tx | Explorer |
|------|----|----------|
| createStream (#3, 0.30 USDC / 60s) | `0xf8a922…d5d209` | https://testnet.arcscan.app/tx/0xf8a922407bd50546d5013fd7f31334ad4ad2e9504559f355b3ab11a21fd5d209 |
| call 1 settled $0.060 | `0x384263…bb6c48` | https://testnet.arcscan.app/tx/0x3842632fc1ae909774501aa6dc2b682ffcdce94eba23d06b0035ff4db8bb6c48 |
| call 2 settled $0.050 | `0x71493d…0ccdb7` | https://testnet.arcscan.app/tx/0x71493d8e4c60fb6b66336a29577f295362b9f5e06353c086989bfd7ee50ccdb7 |
| call 3 settled $0.050 | `0x8b62a3…6b3ce5` | https://testnet.arcscan.app/tx/0x8b62a397a84a66efee4e5e3c3caef1948c2acd0fb7c9b8769a136a5bc76b3ce5 |
| cancel, 0.025 to payee + 0.115 reclaimed | `0x0b8130…8aa475` | https://testnet.arcscan.app/tx/0x0b8130fb6e90941205b84b8615e5a35bdccd76e5c7de505c60bd2e1bed8aa475 |

The agent committed a 0.30 USDC budget, paid 0.185 USDC for the work it actually consumed,
and got 0.115 USDC back by cancelling. Pay only for what you use.

Those two figures are decoded from the cancel transaction's own `Transfer` logs, not taken
from the console: StreamPay sent 0.025 USDC to the payee (accrued since the last per-call
settlement) and 0.115 USDC back to the agent. Add the three settled calls, 0.060 + 0.050 +
0.050, and the payee received 0.185; 0.185 + 0.115 is exactly the 0.30 budget, nothing
stranded in the contract.

The console line above says `reclaimable: $0.120000` because that is a read taken a moment
before the transaction landed, and the stream keeps accruing in between. The chain says
0.115. Where the two disagree, the chain is the record.

The split across the three calls varies between runs: each call bills whatever the stream
has accrued since the previous settlement, which depends on real block timing. The budget
and the rate are fixed; the per-call amounts are not.

## The earlier run (2026-06-09), kept as history

The original transcript settled on StreamPay `0x505739d3…82382450`, which the 2026-07-31
redeploy superseded. Those five transactions still read `status 1` on chain, but their `to`
is the old contract, so they are no longer evidence about the current deployment:
[`0x771131…671572`](https://testnet.arcscan.app/tx/0x771131299c5a876c8d008303409f4bd853968bd92306516098f29716e7671572) (createStream, stream #14),
[`0x96f8a1…fafb8e8`](https://testnet.arcscan.app/tx/0x96f8a1a1fe0d11d883110830304ddbe5a5203c644f8d021d018eb0234fafb8e8),
[`0x9260c6…2ee01f`](https://testnet.arcscan.app/tx/0x9260c636ed09d64555f56143f2a52854daf9d12a4ab241c714fa5c67be2ee01f),
[`0x477834…2d6c40`](https://testnet.arcscan.app/tx/0x4778347679a23124f5f1bb0bffe5ecf0e90486778a50eed34f096cfb7e2d6c40),
[`0x0cfeae…d9eb358`](https://testnet.arcscan.app/tx/0x0cfeae533d89cfee2f2d82ca2fcae08ab802da3668fee68919f3164ebd9eb358) (cancel).
