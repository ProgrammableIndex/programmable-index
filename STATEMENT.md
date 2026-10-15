# Programmable Index (PIDX) — controller statement

```
Programmable Index (PIDX) launches on Ethereum mainnet (chain id 1) through Programmable custom launch profile 3.6.
Controller / launch wallet: 0x15a80CDE1f28C9E1a29c39780e7623f84560180b
Website: https://programmableindex.com/
Sources: https://github.com/ProgrammableIndex/programmable-index
X: https://x.com/ProgrammableIDX
Hook fee on every swap, charged in ETH on the quote side, total buys and sells: 5.00% at launch decaying linearly to 3.00% over 300 seconds, then 3.00% forever. All of it goes to the IndexBasketVaultV1 contract as project-fee owner; the vault keeps an immutable 20% of what it receives as ETH for the dev wallet and converts the rest into the holder reward basket. On-chain limits: the long-run total can never exceed 5.00%, an opening fee above 5% is capped at 25% and must fall to the floor within 300 seconds, and the fee only ever decreases. The hook takes no Programmable share: Programmable's 0.30% platform fee is collected exactly once, by Programmable's own router on trades routed through it. Pool lpFee 0.
Reward basket (immutable): CLAUS 20%, V4 20%, WBTC 20%, WETH 20%, LINK 20%. Dev wallet 0x15a80CDE1f28C9E1a29c39780e7623f84560180b, dev share 20% of the vault's fee income. Keeper 0x15a80CDE1f28C9E1a29c39780e7623f84560180b can only trigger harvests with minimum outputs and never receives funds.
For the first 120 seconds after launch each wallet can buy at most 3% of the supply in total (enforced by the token on transfers out of the Uniswap v4 PoolManager); the limit then switches itself off permanently, cannot be changed or re-enabled, and sells and wallet transfers are never limited.
Successor to Programmable custom launch request abd923d5-26c0-489b-99f5-71e2023a21ce: the opening fee is now within 5% and the hook no longer takes a Programmable share, so the platform fee is collected once.
Liquidity: 100% of the supply is seeded in the launch transaction as a permanently locked single-sided Uniswap v4 position.
This statement is signed by the controller wallet on 2026-10-15 and is the project's own announcement; links to third-party pages are not claims of control.
```

EIP-191 (personal_sign) signature by `0x15a80CDE1f28C9E1a29c39780e7623f84560180b`:

```
09b82550b220c374bec1898f3b42cadbb938f244cf05fcf33c9f3508c59b99087978a32db3d630e4a6f7f02c9a3def112418fad9802a38e4382310fb4754c0c01b
```

Verify: recover the signer of the message block above with any EIP-191 verifier (e.g. Etherscan › Verified Signatures, or `cast wallet verify`).
