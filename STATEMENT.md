# Programmable Index (PIDX) — controller statement

```
Programmable Index (PIDX) launches on Ethereum mainnet (chain id 1) through Programmable custom launch profile 3.6.
Controller / launch wallet: 0x15a80CDE1f28C9E1a29c39780e7623f84560180b
Website: https://programmableindex.com/
Sources: https://github.com/ProgrammableIndex/programmable-index
X: https://x.com/ProgrammableIDX
Hook fee on every swap, charged in ETH on the quote side, total buys and sells: 5.00% at launch decaying linearly to 3.00% over 300 seconds, then 3.00% forever. Of it, 0.30% of the gross ETH leg of every swap (through any router, the initial buy included) accrues to the Programmable treasury 0xD88539d3c4C460136a733A3Fd60cf6BF269079da as backed PoolManager ETH claims that anyone can trigger to be paid only there, and the rest goes to the IndexBasketVaultV1 contract as project-fee owner; the vault keeps an immutable 20% of what it receives as ETH for the dev wallet and converts the rest into the holder reward basket. On-chain limits: the long-run total can never exceed 5.00%, an opening fee above 5% is capped at 25% and must fall to the floor within 300 seconds, and the fee only ever decreases. The project has no buyback path in this pool (the vault only buys CLAUS, V4, WBTC, WETH and LINK in other pools). Pool lpFee 0.
Reward basket (immutable): CLAUS 20%, V4 20%, WBTC 20%, WETH 20%, LINK 20%. Dev wallet 0x15a80CDE1f28C9E1a29c39780e7623f84560180b, dev share 20% of the vault's fee income. Keeper 0x15a80CDE1f28C9E1a29c39780e7623f84560180b can only trigger harvests with minimum outputs and never receives funds.
For the first 120 seconds after launch each wallet can buy at most 3% of the supply in total (enforced by the token on transfers out of the Uniswap v4 PoolManager); the limit then switches itself off permanently, cannot be changed or re-enabled, and sells and wallet transfers are never limited.
Successor to Programmable custom launch request 94fc4a51-575d-48de-b293-924561aa3f3a: the hook now enforces Programmable's 0.30% on every buy and sell through any router, including the initial buy, accruing only to Programmable's treasury; with the native30 route (no extra router fee) that is exactly one 0.30% platform charge. Fee proof: https://github.com/ProgrammableIndex/programmable-index/blob/main/proof/PIDX_native30_fee_proof.md
Liquidity: 100% of the supply is seeded in the launch transaction as a permanently locked single-sided Uniswap v4 position.
This statement is signed by the controller wallet on 2026-10-15 and is the project's own announcement; links to third-party pages are not claims of control.
```

EIP-191 (personal_sign) signature by `0x15a80CDE1f28C9E1a29c39780e7623f84560180b`:

```
f96d080acaf4ac4cedf75fb68c91b4104fabb4e8a3fcb4398ef382003870b01641b6e8f506a38f9b10f3fa05e694e4a3d6ea395d5e17e1177f690240db16a97c1b
```

Verify: recover the signer of the message block above with any EIP-191 verifier (e.g. Etherscan › Verified Signatures, or `cast wallet verify`).
