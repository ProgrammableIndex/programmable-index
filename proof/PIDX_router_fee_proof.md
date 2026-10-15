# PIDX: one platform fee per trade through Programmable's router

For the PIDX custom launch request that names `8f52dd61-1d54-4960-aee8-a6eb3d00c21c` as its predecessor (that request replaced `abd923d5-26c0-489b-99f5-71e2023a21ce`)
Sources: `src/` of https://github.com/ProgrammableIndex/programmable-index, byte-identical to commit `10cef9eb7242cc96592cdc6a142b6d42adba4420` (the contracts are unchanged; later commits only add this proof)
Fork: Ethereum mainnet block 26194706 (`0xea3ea43417f163d0104876695c98dbd6898fe8831209bc2bb2e4793a20fb087e`)
Test: `ProgrammableRouterFeeProof.t.sol` (5/5 pass; output in `data/forge_test_output.txt`)

## Result

| Path | Programmable fee to treasury `0xD885…79da` | Hook fee to Programmable | Hook fee to project vault |
|---|---|---|---|
| Initial buy (launch tx, 0.06 ETH dev buy) | 0 | 0 | 0.003 ETH (5%) |
| Routed buy, launch window, 0.05 ETH | 0.00015 ETH = 0.30% of 0.05 ETH | 0 | 0.0024925 ETH (5% of 0.04985) |
| Routed sell, launch window, 10.9M PIDX | 0.0000682501 ETH = 0.30% of the 0.0227500 ETH gross credit | 0 | 0.0011974 ETH (5%) |
| Routed buy after 300 s, 1 ETH | 0.003 ETH = 0.30% of 1 ETH | 0 | 0.02991 ETH (3% of 0.997) |
| Routed sell after 300 s, whole bag | 0.0028142 ETH = 0.30% of the 0.9380773 ETH gross credit | 0 | 0.0290127 ETH (3%) |

Every routed trade pays the platform fee exactly once: Programmable's router collects it, and the hook's `programmableFeesAccrued()` stays 0 throughout. The hook constant is `PROGRAMMABLE_HUNDREDTHS_OF_BIP = 0`. After each trade the router holds 0 ETH and 0 PIDX.

## The trade path tested

Router: Programmable's UniversalRouter `0xd92A36B0000531EF3063dEd4De20A0783308446C`. It is the `transaction.to` returned by `POST https://programmable.market/api/swap/ethereum/prepare`.

Fee policy: `programmable.ethereum-routed-native-fee.v2` (policyHash `sha256:e2025776…b4b5`), mode `programmable_routed`, 30 bps. The buy fee is on the funded native input; the sell fee is on the gross native output credit.

Calldata is built exactly like the site's own builder, `ethereumStampedSwapTransaction` (verbatim in `data/programmable_market_swap_builder_excerpt.js`):

- **Buy:** `TRANSFER(ETH, treasury, amountIn·30/10000)`, then `V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]`, then `SWEEP(ETH, msg.sender)`
- **Sell:** the two approvals Programmable prepares (`token → Permit2` and `Permit2 → router`), then `V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_PORTION(ETH, treasury, 30), TAKE_ALL]`, then `SWEEP(ETH, msg.sender)`
- **minOut:** the quote with 300 bps slippage, the same as the prepare endpoint uses.

Builder check (`test_0`): the test's builder reproduces, byte for byte, the calldata Programmable's prepare endpoint returned for a live `programmable_routed` token. That was Temo `0x0f8B…1A2D`, buy 0.1 ETH, `platformFeeAmount` 300000000000000. The raw response is in `data/prepare_temo_buy_programmable_routed.json`.

For contrast, a native30 pool (brownies) gets `routedRateBps 0` and no `TRANSFER` (`data/prepare_brownies_buy_native30.json`).

PIDX can't be quoted by the endpoint until it is launched and stamped. The same builder is therefore applied to the PIDX pool key on the fork.

## Initial buy

The dev buy (0.06 ETH, about 27.6M PIDX, 2.76%) runs inside the launch transaction. The path is graph factory, then initializer, then PoolManager; Programmable's router is not involved.

- The hook takes its 5% launch fee for the project vault.
- With the hook's Programmable share at 0, this path pays no Programmable fee.
- It is never charged twice.

If Programmable wants exactly one fee on this path too, the hook can charge the 0.30% Programmable share only when the swap sender is the launch initializer. That makes it one fee on every Programmable path, and it takes a contract change plus a successor request. We'll ship it if you confirm that's what you want.

## Reproduce

Run this with the four `src/*.sol` files from commit `10cef9e` in `src/`, and this test in `test/`, inside a Foundry project (solc 0.8.26, via_ir, cancun, v4-core and OpenZeppelin remappings):

```
anvil --fork-url <mainnet RPC> --fork-block-number 26194706 --port 8547
forge test --match-contract ProgrammableRouterFeeProofTest --fork-url http://127.0.0.1:8547 -vv
```

Fork deployment note: the hook is deployed with `deployCodeTo` at a flag-valid address, and the launch is called by impersonating the graph factory `0xB012…A887`. Constructor arguments, the fee schedule (5% → 3% over 300 s, both sides), the 3% buy limit for 120 s and the dev buy all match the submitted launch.
