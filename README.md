# Oracle1

Oracle1 is the signed RWA attestation layer used by **MAKE MY COIN**. It gives an
RWA project a consistent way to define a feed, authorize independent
attestors, accept a quorum of matching reports, reject stale or extreme data,
pause on disputes, and preserve a permanent round history.

## What Oracle1 proves

Oracle1 proves that the configured attestors signed the same EIP-712 report for
the same feed, round, value, timestamp, validity window, and evidence hash.

Oracle1 does **not** create legal title, authenticate an asset, remove a lien,
guarantee an appraisal, provide regulatory approval, or make an illiquid asset
liquid. Those claims still depend on authoritative offchain records and
qualified professionals.

## Production controls

- EIP-712 domain separation by chain and contract
- monotonic feed round numbers for replay protection
- multiple authorized reporters with configurable quorum
- EOA and ERC-1271 smart-account signature support
- reporter de-duplication through strict address ordering
- observation timestamps, validity windows, and staleness limits
- value bounds and maximum-deviation circuit breakers
- per-feed and system-wide emergency pause controls
- controller transfer through a two-step acceptance flow
- dispute, invalidation, and resolution hashes
- immutable event and round history

## RWA report lifecycle

1. The asset owner completes the MAKE MY COIN RWA evidence plan.
2. A feed is created with a metadata hash, scale, quorum, age limit, bounds,
   and deviation limit.
3. The controller authorizes the named attestor wallets.
4. Each attestor reviews the source evidence and signs the same typed report.
5. Anyone can relay the quorum to the contract; the relayer does not need to
   be trusted.
6. The registry verifies every signature and control before accepting a round.
7. Consumer contracts call `latestData` and proceed only when `usable` is true.
8. A controller or guardian can pause a disputed feed. A guardian resolution
   may invalidate the challenged round without deleting history.

## Local setup

```bash
npm install
npm run compile
npm test
```

The Hardhat configuration uses the locally installed, pinned Solidity compiler
so verification builds do not depend on downloading a compiler at runtime.

## Base Sepolia deployment

Copy `.env.example` to `.env`, use a test-only deployer, and run:

```bash
npm run deploy:base-sepolia
```

Never commit private keys. The MAKE MY COIN production interface uses the
connected creator wallet for testnet actions instead of taking custody of keys.

## Signed report schema

```text
Report(
  bytes32 feedId,
  uint64 roundId,
  int192 value,
  uint64 observedAt,
  uint64 validUntil,
  bytes32 evidenceHash
)
```

`value` is fixed-point and uses the feed's configured `decimals`. The
`evidenceHash` should be the keccak256 hash of a canonical evidence manifest.
Sensitive documents should remain in access-controlled storage; do not publish
personal or confidential records on a public blockchain or public IPFS.

## Security status

The new registry includes automated tests and explicit safety controls, but it
has not received an independent security audit. Use Base Sepolia until an audit,
deployment verification, key-management plan, monitoring, and incident-response
runbook are complete.

## Legacy experiments

The tested Oracle1 package lives in `contracts-production/`. Earlier
prediction-market, MEV, AI, and DeFi experiments remain under `contracts/`.
They are educational examples, are excluded from the production compiler, and
are not part of the Oracle1 RWA package.

## License

MIT
