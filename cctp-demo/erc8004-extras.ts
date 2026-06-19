/**
 * ERC-8004 extras on Arc: (1) a real ReputationRegistry feedback to Aiden from a fresh
 * counterparty, and (2) bind an operational agent wallet to Aiden's identity via
 * IdentityRegistry.setAgentWallet (EIP-712 signed by the operational wallet).
 * Owner/funder = the burner (env DEPLOYER_PRIVATE_KEY); fresh keys are generated in-process.
 * Run: node --import tsx erc8004-extras.ts
 */
import {
  createWalletClient, createPublicClient, http, defineChain, encodeFunctionData, getAddress, parseEther,
} from 'viem'
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts'

const PK = (process.env.DEPLOYER_PRIVATE_KEY) as `0x${string}`
if (!PK) throw new Error('set DEPLOYER_PRIVATE_KEY (burner)')

const arc = defineChain({
  id: 5042002, name: 'Arc Testnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.arc.network'] } },
  blockExplorers: { default: { name: 'Arcscan', url: 'https://testnet.arcscan.app' } },
})
const IDR = getAddress('0x8004A818BFB912233c491871b3d84c89A494BD9e')
const REP = getAddress('0x8004B663056A597Dffe9eCcC1965A193B7388713')
const AIDEN = 471762n

const idrAbi = [
  { type: 'function', name: 'setAgentWallet', stateMutability: 'nonpayable', inputs: [
    { name: 'agentId', type: 'uint256' }, { name: 'newWallet', type: 'address' },
    { name: 'deadline', type: 'uint256' }, { name: 'signature', type: 'bytes' }], outputs: [] },
  { type: 'function', name: 'getAgentWallet', stateMutability: 'view', inputs: [{ name: 'a', type: 'uint256' }], outputs: [{ type: 'address' }] },
] as const
const repAbi = [
  { type: 'function', name: 'giveFeedback', stateMutability: 'nonpayable', inputs: [
    { name: 'agentId', type: 'uint256' }, { name: 'value', type: 'int128' }, { name: 'valueDecimals', type: 'uint8' },
    { name: 'tag1', type: 'string' }, { name: 'tag2', type: 'string' }, { name: 'endpoint', type: 'string' },
    { name: 'feedbackURI', type: 'string' }, { name: 'feedbackHash', type: 'bytes32' }], outputs: [] },
  { type: 'function', name: 'readFeedback', stateMutability: 'view', inputs: [
    { name: 'agentId', type: 'uint256' }, { name: 'client', type: 'address' }, { name: 'idx', type: 'uint64' }],
    outputs: [{ type: 'int128' }, { type: 'uint8' }, { type: 'string' }, { type: 'string' }, { type: 'bool' }] },
] as const

const owner = privateKeyToAccount(PK)
const pub = createPublicClient({ chain: arc, transport: http() })
const ownerWallet = createWalletClient({ account: owner, chain: arc, transport: http() })
const ZERO32 = ('0x' + '00'.repeat(32)) as `0x${string}`

async function fundGas(to: `0x${string}`, eth: string) {
  const tx = await ownerWallet.sendTransaction({ to, value: parseEther(eth) }) // Arc native = USDC gas
  await pub.waitForTransactionReceipt({ hash: tx }); return tx
}

async function main() {
  const out: any = { owner: owner.address }

  // ── 1) ReputationRegistry: a fresh counterparty leaves real feedback for Aiden ──
  const cpKey = generatePrivateKey()
  const cp = privateKeyToAccount(cpKey)
  const cpWallet = createWalletClient({ account: cp, chain: arc, transport: http() })
  console.log(`» counterparty ${cp.address} — funding Arc gas …`)
  out.fund_counterparty = await fundGas(cp.address, '0.05')
  console.log('» giveFeedback(Aiden) from counterparty …')
  const fbTx = await cpWallet.sendTransaction({
    to: REP, data: encodeFunctionData({ abi: repAbi, functionName: 'giveFeedback',
      args: [AIDEN, 5n, 0, 'research-quality', 'on-time-delivery', '', '', ZERO32] }),
  })
  await pub.waitForTransactionReceipt({ hash: fbTx })
  const fb = await pub.readContract({ address: REP, abi: repAbi, functionName: 'readFeedback', args: [AIDEN, cp.address, 1n] }) // feedback index is 1-based
  out.feedback = { tx: fbTx, client: cp.address, read: { value: fb[0].toString(), decimals: fb[1], tag1: fb[2], tag2: fb[3], revoked: fb[4] } }
  console.log(`» feedback stored: value=${fb[0]} tag1=${fb[2]} tag2=${fb[3]}  (tx ${fbTx})`)

  // ── 2) IdentityRegistry: bind an operational wallet to Aiden (EIP-712 signed by that wallet) ──
  const opKey = generatePrivateKey()
  const op = privateKeyToAccount(opKey)
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 240) // < 5 min
  const signature = await createWalletClient({ account: op, chain: arc, transport: http() }).signTypedData({
    domain: { name: 'ERC8004IdentityRegistry', version: '1', chainId: 5042002, verifyingContract: IDR },
    types: { AgentWalletSet: [
      { name: 'agentId', type: 'uint256' }, { name: 'newWallet', type: 'address' },
      { name: 'owner', type: 'address' }, { name: 'deadline', type: 'uint256' }] },
    primaryType: 'AgentWalletSet',
    message: { agentId: AIDEN, newWallet: op.address, owner: owner.address, deadline },
  })
  console.log(`» setAgentWallet(Aiden → ${op.address}) submitted by owner …`)
  const swTx = await ownerWallet.sendTransaction({
    to: IDR, data: encodeFunctionData({ abi: idrAbi, functionName: 'setAgentWallet', args: [AIDEN, op.address, deadline, signature] }),
  })
  await pub.waitForTransactionReceipt({ hash: swTx })
  const bound = await pub.readContract({ address: IDR, abi: idrAbi, functionName: 'getAgentWallet', args: [AIDEN] })
  out.agent_wallet = { tx: swTx, opWallet: op.address, bound_onchain: bound, ok: bound.toLowerCase() === op.address.toLowerCase() }
  console.log(`» agent wallet bound: getAgentWallet(Aiden)=${bound}  ok=${out.agent_wallet.ok}`)

  console.log('\nRESULT:', JSON.stringify(out, null, 2))
}
main().catch((e) => { console.error('✗', e); process.exit(1) })
