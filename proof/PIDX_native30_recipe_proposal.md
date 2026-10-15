# PIDX: proposed exact-runtime and fee-accrual profile for Programmable's routed-fee exemption

For request `85951f14-9dfb-4c4f-b1ef-d1e66e046aee`. Its contracts are unchanged, and nothing will be repacked until this path is agreed.

Programmable's review of `85951f14` confirmed:

- the restored 30 bps pool fee
- that all four contracts compile to the packed creation bytecode
- that the exact launch graph deploys
- that the 0.06 ETH initial buy and a direct buy passed on a fork

What remains is on the website side: the production verifier has no recipe for this hook, so the website encoder adds a second 30 bps routed charge. This file gives the data for a recipe in the same shape as `programmable.ethereum-native30-runtime-proof.v1` (cf. `brownie_native30_optimizer1000_v1`).

## Proposed proof fields

| Field | Value |
|---|---|
| recipeId (suggested) | `pidx_decaying_volume_fee_v1` |
| market | the exact pool key of request 85951f14: `currency0 = 0x0` (ETH), `currency1` = PIDX token, `fee = 0`, `tickSpacing = 60`, `hooks` = DecayingVolumeFeeHookV1 (addresses as bound in the request) |
| recipient | `0xD88539d3c4C460136a733A3Fd60cf6BF269079da` (`PROGRAMMABLE_FEE_OWNER`, a compile-time constant) |
| rateBps / denominator | 30 / 10000 (`PROGRAMMABLE_HUNDREDTHS_OF_BIP = 3000` of `RATE_DENOMINATOR = 1_000_000`, constants) |
| scope | `exact_pool_key`: one canonical pool id. Registration happens once, through the registrar (the launch initializer), and every hook callback checks `_requireCanonicalPool` |
| feeCurrency | `native` (`quoteCurrencyAddress = address(0)`) |
| assessmentBase | `gross_native_leg`: the specified ETH for ETH-specified swaps; the executed pool ETH amount for token-specified swaps (exact output uses the witness path) |
| rounding | floor per trade with a carried sub-wei remainder (reference-kernel accounting). Per trade the accrual is `floor(gross*30/10000)` or that value plus 1 wei, and it is exact cumulatively. If your verifier needs strict `floor_per_trade`, it is a one-line change; tell us before we repack |
| accrual | `backed_pool_manager_native_claims`: the fee is taken as PoolManager ERC-6909 claims for id 0 (ETH) held by the hook. `totalQuoteFeesAccrued == programmable + project`, and `PoolManager.balanceOf(hook, 0) >= totalQuoteFeesAccrued` |
| claim | `permissionless_fixed_recipient`: `claimProgrammableFees()` (selector `0xa95e4f21`) takes no arguments, anyone may call it, and it always pays `PROGRAMMABLE_FEE_OWNER`. Event: `ProgrammableFeesClaimed(bytes32,address,address,address,uint256)`, topic0 `0xeadf8488...1722` |
| feeVault / feeRecorder | the hook address (claims are held and recorded in the hook) |

## Runtime binding

- **role:** hook
- **runtimeCodeHash:** computed from the packed creation bytecode of request 85951f14 (you already compiled and deployed it on your fork)
- **immutableWords:**
  - `poolManager`: `0x000000000004444c5dc75cB358380D2e3dE08A90`
  - `registrar`: the launch initializer of request 85951f14
  - `quoteCurrencyAddress`: `0x0`

There is no owner, admin, upgrade or setter path. The fee schedules are bound once at registration and can only decrease over time:

- buy and sell 5% -> 3% linearly over 300 s
- launch-window total capped at 25%, long-run total at 5%

`runtimeConfigurationHash()` returns a single receipt of the post-registration configuration.

## Accrual readback for the verifier

| Read | How |
|---|---|
| Platform accrual | `programmableFeesAccrued()` (`0x0986bdb6`), or storage `_claimableLiability[poolId][0x0][0xD885...79da]`, mapping at slot 11 (`mapping(bytes32 => mapping(address => mapping(address => uint256)))`) |
| Project accrual | `projectFeesAccrued()` (`0x19a08594`) |
| Total | `totalQuoteFeesAccrued()` (`0x7d36c30c`), slot 7 |
| Remainder | `programmableFeeRemainder`, slot 8 |
| Backing | `PoolManager.balanceOf(hook, 0)` |

So the per-trade evidence for a website trade is: `change in programmableFeesAccrued` = 30 bps of the gross native leg, `change in treasury ETH` = 0 during the trade (no `TRANSFER` / `TAKE_PORTION`), and backing >= liabilities afterwards.

## Evidence already published

[PIDX_native30_fee_proof.md](PIDX_native30_fee_proof.md) shows, on a mainnet fork (block 26194706):

- the initial buy accrues exactly 0.00018 ETH (0.30% of 0.06)
- buys and sells through `0xd92A...446C`, with your builder's native30 calldata (byte-identical to your brownies prepare response), accrue exactly one 0.30% with zero router transfer
- Uniswap's router and a bare PoolManager router accrue the same
- a permissionless claim pays the fixed recipient exactly the accrued amount

Once the recipe is live, we will provide current website buy/sell evidence (prepare response with `routedRateBps 0`, the transaction, and the accrual delta) for the deployed pool.

## Alternative: a supported kernel integration

If you prefer not to add a custom recipe, we're open to moving to a supported kernel (EthereumNative30HookV3 / EthereumNativeFeeVaultV3, or another integration you name). The condition is that it keeps the approved economics: 5% -> 3% over 300 s, the 3% max buy for 120 s that expires strictly, and permanently locked liquidity. Tell us which one, and we'll prepare it before any repack.
