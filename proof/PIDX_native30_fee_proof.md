# PIDX: the hook enforces Programmable's 0.30% on every trade

This proof is for the PIDX custom launch request that names `94fc4a51-575d-48de-b293-924561aa3f3a` as its predecessor. That request replaced `8f52dd61…`, which replaced `abd923d5…`; only the newest package should ever be deployed.

- **Fork:** Ethereum mainnet block 26194706 (`0xea3ea43417f163d0104876695c98dbd6898fe8831209bc2bb2e4793a20fb087e`)
- **Test:** `ProgrammableNative30FeeProof.t.sol`, 7/7 pass; raw output in `data/forge_test_output.txt`. The 11 existing project fork tests also pass.
- **Source change:** only `src/DecayingVolumeFeeHookV1.sol` changed (`data/hook_diff_vs_94fc4a51.diff`). Token, vault and initializer are unchanged.

## What changed in the hook

1. `PROGRAMMABLE_HUNDREDTHS_OF_BIP = 3000`. The hook charges 0.30% of the gross native (ETH) leg of every swap in the exact PIDX pool, whoever routes it. That includes the initial buy inside the launch transaction.
2. `claimProgrammableFees()` is now permissionless and has no recipient argument. It always pays `PROGRAMMABLE_FEE_OWNER = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da`; nothing else can move these claims.
3. Disclosed project economics are unchanged:
   - total hook fee 5% at launch, decaying linearly to 3% over 300 s (buys and sells), then 3% forever
   - 3% max buy per wallet for 120 s
   - all of these bounds are immutable
   - the 0.30% sits inside that total, so the project vault gets 4.70% → 2.70%
4. There are no project buybacks in this pool. The vault only buys CLAUS, V4, WBTC, WETH and LINK, in other pools.

## Match with the pool-enforced (native30) properties

| Property (from Programmable's native30 runtime proof) | PIDX hook |
|---|---|
| scope `exact_pool_key` | `_requireCanonicalPool`: one registered pool id, `beforeInitialize` only through the hook itself |
| feeCurrency `native`, assessmentBase `gross_native_leg` | fee on the ETH leg: the specified ETH for ETH-specified swaps, the executed pool ETH amount for token-specified swaps |
| rate 30 bps, recipient `0xD885…79da` | `PROGRAMMABLE_HUNDREDTHS_OF_BIP = 3000` of `RATE_DENOMINATOR = 1e6`; `PROGRAMMABLE_FEE_OWNER` constant |
| accrual `backed_pool_manager_native_claims` | `_accrue` takes the fee as PoolManager ERC-6909 ETH claims (`take(..., claims=true)`) and enforces `totalQuoteFeesAccrued == platform + project` |
| claim `permissionless_fixed_recipient` | `claimProgrammableFees()`: anyone, always to `PROGRAMMABLE_FEE_OWNER` |
| rounding | floor per trade, plus the reference kernel's carried sub-wei remainder (at most +1 wei on a trade, exact over time) |

## Results (fork)

| Trade | Gross ETH leg | Hook → Programmable | Hook → vault | Router transfer to treasury |
|---|---|---|---|---|
| Initial buy, launch tx, 0.06 ETH (5%) | 0.06 | 0.00018 (0.30%) | 0.00282 (4.70%) | 0 |
| Programmable route buy, 0.05 ETH (5%) | 0.05 | 0.00015 (0.30%) | 0.00235 | 0 |
| Programmable route sell, launch window (5%) | 0.0240203 | 0.0000720608 (0.30%) | 0.0011290 | 0 |
| Programmable route buy, 1 ETH, after 300 s (3%) | 1.0 | 0.003 (0.30%) | 0.027 | 0 |
| Programmable route sell, after 300 s (3%) | 0.97 | 0.00291 (0.30%) | 0.02619 | 0 |
| Uniswap Universal Router buy / sell (3%) | 0.5 / 0.485 | 0.0015 / 0.001455 | 0.0135 / 0.013095 | 0 |
| Bare PoolManager router buy / sell (3%) | 0.5 / 0.485 | 0.0015 / 0.001455 | | 0 |

- **Actual payment:** an unrelated address called `claimProgrammableFees()`. The treasury received exactly the accrued 0.0004725 ETH, the caller received nothing, and the hook's ERC-6909 claims were burned 1:1 (`test_5`).
- **Backing:** after every test, `PoolManager.balanceOf(hook, ETH) >= totalQuoteFeesAccrued`.

## The route

"Programmable route" means UniversalRouter `0xd92A36B0000531EF3063dEd4De20A0783308446C` with calldata built exactly like the programmable.market builder (`data/programmable_market_swap_builder_excerpt.js`). For a pool-enforced (native30) pool the builder:

- sends the full amount into `V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]`, then `SWEEP`
- adds no `TRANSFER` and no `TAKE_PORTION`

The test's builder reproduces Programmable's own prepare responses byte for byte in both modes (`test_0`):

- **native30 mode:** brownies (`data/prepare_brownies_buy_native30.json`)
- **routed mode:** Temo (`data/prepare_temo_buy_programmable_routed.json`)

On that route PIDX pays exactly one 0.30% platform charge, the hook's.

`test_6` documents the other case for completeness. If the server kept `programmable_routed` for this pool, the router would add a second 0.30% (`TRANSFER`) on top of the enforced hook share. We ask for the pool-enforced route (`routedRateBps 0`) for this exact hook and vault runtime, as bound in the request.

## Reproduce

Put the four `src/*.sol` files from the repo in `src/` and this test in `test/` of a Foundry project (solc 0.8.26, via_ir, cancun, v4-core and OpenZeppelin remappings), then run:

```
anvil --fork-url <mainnet RPC> --fork-block-number 26194706 --port 8547
forge test --match-contract ProgrammableNative30FeeProofTest --fork-url http://127.0.0.1:8547 -vv
```

On the fork, the hook is placed at a flag-valid address with `deployCodeTo`, and the launch is executed by impersonating the graph factory `0xB012…A887`. Constructor arguments, the fee schedule, the buy limit and the 0.06 ETH dev buy match the submitted launch.
