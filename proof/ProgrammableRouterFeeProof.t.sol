// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { DecayingVolumeFeeHookV1 } from "../src/DecayingVolumeFeeHookV1.sol";
import { IndexRewardTokenV1 } from "../src/IndexRewardTokenV1.sol";
import { IndexBasketVaultV1 } from "../src/IndexBasketVaultV1.sol";
import { IndexSeededLaunchInitializerV1 } from "../src/IndexSeededLaunchInitializerV1.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// Same layout as v4-periphery IV4Router.ExactInputSingleParams (verified router source).
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// Proof that PIDX trades through Programmable's own trade path pay exactly ONE platform fee.
///
/// Trade path = Programmable's UniversalRouter 0xd92A36B0000531EF3063dEd4De20A0783308446C, with calldata
/// built exactly like programmable.market's `ethereumStampedSwapTransaction` (fc/fd in the site bundle) for a
/// `programmable_routed` route (policy programmable.ethereum-routed-native-fee.v2, 30 bps, recipient treasury):
///   buy : TRANSFER(ETH, treasury, amountIn*30/10000) | V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL] | SWEEP(ETH, msg.sender)
///   sell: V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_PORTION(ETH, treasury, 30), TAKE_ALL] | SWEEP(ETH, msg.sender)
/// The builder is checked byte-for-byte against a live calldata returned by
/// POST https://programmable.market/api/swap/ethereum/prepare (Temo, programmable_routed).
contract ProgrammableRouterFeeProofTest is Test {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant FACTORY = 0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887;
    address constant ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant TREASURY = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address constant MSG_SENDER = address(1);
    uint256 constant ROUTED_BPS = 30;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CLAUS = 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    address constant V4 = 0x7987f03462200b3D8A072E02C89A8A41dCB124EE;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant WBTC_WETH_V3 = 0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0;
    address constant LINK_WETH_V3 = 0xa6Cc3C2531FdaA6Ae1A3CA84c2855806728693e8;

    // production launch settings (programmable_index_launch.py after the successor fix)
    address constant LAUNCHER = 0x15a80CDE1f28C9E1a29c39780e7623f84560180b;
    uint256 constant DEV_BUY = 0.06 ether;
    uint256 constant MAX_BUY = 30_000_000e18;
    int24 constant TICK_UPPER = 200280;
    int24 constant TICK_LOWER = -887220;

    address alice = makeAddr("pidx-router-proof-trader");

    IndexSeededLaunchInitializerV1 init;
    IndexRewardTokenV1 token;
    IndexBasketVaultV1 vault;
    DecayingVolumeFeeHookV1 hook;
    PoolKey key;

    uint256 initTreasuryDelta;
    uint256 initHookProjectFee;
    uint256 initProgrammableAccrued;
    uint256 initDevTokens;

    function _routes() internal pure returns (IndexBasketVaultV1.RewardRoute[] memory r) {
        r = new IndexBasketVaultV1.RewardRoute[](5);
        r[0] = IndexBasketVaultV1.RewardRoute(CLAUS, IndexBasketVaultV1.RouteKind.UNISWAP_V4_NATIVE, 2000, address(0), 8388608, 1, 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf);
        r[1] = IndexBasketVaultV1.RewardRoute(V4, IndexBasketVaultV1.RouteKind.UNISWAP_V4_NATIVE, 2000, address(0), 0, 200, 0x025a386eAa79f6067d29848FD05ccC71bEAb20CC);
        r[2] = IndexBasketVaultV1.RewardRoute(WBTC, IndexBasketVaultV1.RouteKind.UNISWAP_V3, 2000, WBTC_WETH_V3, 0, 0, address(0));
        r[3] = IndexBasketVaultV1.RewardRoute(WETH, IndexBasketVaultV1.RouteKind.WRAP_WETH, 2000, address(0), 0, 0, address(0));
        r[4] = IndexBasketVaultV1.RewardRoute(LINK, IndexBasketVaultV1.RouteKind.UNISWAP_V3, 2000, LINK_WETH_V3, 0, 0, address(0));
    }

    function setUp() public {
        init = new IndexSeededLaunchInitializerV1(PM, FACTORY, 0, 60, TICK_LOWER, TICK_UPPER);
        vault = new IndexBasketVaultV1(PM, WETH, address(init), LAUNCHER, LAUNCHER, 2000, 0, 3 days, _routes());
        token = new IndexRewardTokenV1("Programmable Index", "PIDX", 1e27, address(init), 1e27, LAUNCHER, address(PM), address(vault), MAX_BUY, 120);
        address hookAddr = address(uint160(0x20cc) | (uint160(uint256(keccak256("pidx-hook"))) & ~uint160(0x3fff)));
        deployCodeTo("DecayingVolumeFeeHookV1.sol:DecayingVolumeFeeHookV1", abi.encode(PM, address(init), address(0)), hookAddr);
        hook = DecayingVolumeFeeHookV1(hookAddr);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 0, 60, IHooks(hookAddr));

        // initial-buy path: the launch transaction itself (graph factory -> initializer -> seeded pool + dev buy)
        DecayingVolumeFeeHookV1.FeeSchedule memory s = DecayingVolumeFeeHookV1.FeeSchedule(50_000, 30_000, 300);
        uint256 t0 = TREASURY.balance;
        vm.deal(FACTORY, 1 ether);
        vm.prank(FACTORY);
        init.initialize{ value: DEV_BUY }(address(token), hookAddr, payable(address(vault)), LAUNCHER, 1, s, s);
        initTreasuryDelta = TREASURY.balance - t0;
        initHookProjectFee = hook.projectFeesAccrued();
        initProgrammableAccrued = hook.programmableFeesAccrued();
        initDevTokens = token.balanceOf(LAUNCHER);

        require(alice.code.length == 0, "trader must be a plain EOA");
        vm.deal(alice, 100 ether);
    }

    // ---------------------------------------------------------------- calldata builder (mirrors programmable.market fc)

    function _calldata(PoolKey memory k, bool buy, uint256 amountIn, uint256 minOut, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
        address tok = Currency.unwrap(k.currency1);
        uint256 fee = buy ? amountIn * ROUTED_BPS / 10_000 : 0;
        uint256 net = amountIn - fee;

        bytes memory actions;
        bytes[] memory params;
        ExactInputSingleParams memory sp = ExactInputSingleParams(k, buy, uint128(net), uint128(minOut), "");
        if (buy) {
            actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
            params = new bytes[](3);
            params[0] = abi.encode(sp);
            params[1] = abi.encode(address(0), net);
            params[2] = abi.encode(tok, minOut);
        } else {
            actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x10), uint8(0x0f));
            params = new bytes[](4);
            params[0] = abi.encode(sp);
            params[1] = abi.encode(tok, net);
            params[2] = abi.encode(address(0), TREASURY, ROUTED_BPS);
            params[3] = abi.encode(address(0), minOut);
        }

        bytes memory commands;
        bytes[] memory inputs;
        if (buy) {
            commands = abi.encodePacked(uint8(0x05), uint8(0x10), uint8(0x04));
            inputs = new bytes[](3);
            inputs[0] = abi.encode(address(0), TREASURY, fee);
            inputs[1] = abi.encode(actions, params);
            inputs[2] = abi.encode(address(0), MSG_SENDER, uint256(0));
        } else {
            commands = abi.encodePacked(uint8(0x10), uint8(0x04));
            inputs = new bytes[](2);
            inputs[0] = abi.encode(actions, params);
            inputs[1] = abi.encode(address(0), MSG_SENDER, uint256(0));
        }
        return abi.encodeWithSignature("execute(bytes,bytes[],uint256)", commands, inputs, deadline);
    }

    /// quote like Programmable's prepare endpoint: simulate with minOut 1, then minOut = out * (1 - 3% slippage)
    function _quote(bool buy, uint256 amountIn) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        out = _execute(buy, amountIn, 1).received;
        vm.revertToState(snap);
    }

    struct Trade {
        uint256 treasuryFee;
        uint256 hookProjectFee;
        uint256 hookProgrammableFee;
        uint256 received;
        uint256 spent;
        uint256 gas;
    }

    function _execute(bool buy, uint256 amountIn, uint256 minOut) internal returns (Trade memory t) {
        bytes memory data = _calldata(key, buy, amountIn, minOut, block.timestamp + 240);
        uint256 tre = TREASURY.balance;
        uint256 hp = hook.projectFeesAccrued();
        uint256 hq = hook.programmableFeesAccrued();
        uint256 eth = alice.balance;
        uint256 bal = token.balanceOf(alice);
        vm.startPrank(alice);
        if (!buy) {
            token.approve(PERMIT2, amountIn); // "token-to-permit2" approval prepared by Programmable
            IPermit2(PERMIT2).approve(address(token), ROUTER, uint160(amountIn), uint48(block.timestamp + 240 + 3600)); // "permit2-to-router"
        }
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = ROUTER.call{ value: buy ? amountIn : 0 }(data);
        t.gas = g - gasleft();
        vm.stopPrank();
        if (!ok) {
            assembly { revert(add(ret, 32), mload(ret)) }
        }
        t.treasuryFee = TREASURY.balance - tre;
        t.hookProjectFee = hook.projectFeesAccrued() - hp;
        t.hookProgrammableFee = hook.programmableFeesAccrued() - hq;
        if (buy) {
            t.received = token.balanceOf(alice) - bal;
            t.spent = eth - alice.balance;
        } else {
            t.received = alice.balance - eth;
            t.spent = bal - token.balanceOf(alice);
        }
        assertEq(ROUTER.balance, 0, "router keeps no ETH");
        assertEq(token.balanceOf(ROUTER), 0, "router keeps no PIDX");
    }

    function _trade(bool buy, uint256 amountIn, string memory label) internal returns (Trade memory t) {
        uint256 q = _quote(buy, amountIn);
        uint256 minOut = q * (10_000 - 300) / 10_000;
        t = _execute(buy, amountIn, minOut);
        assertGe(t.received, minOut, "min out");
        assertEq(t.hookProgrammableFee, 0, "hook takes no Programmable share");
        assertEq(hook.programmableFeesAccrued(), 0, "hook Programmable ledger stays 0");
        console2.log(label);
        console2.log("  amount in (wei)          ", amountIn);
        console2.log("  received (wei)           ", t.received);
        console2.log("  treasury platform fee    ", t.treasuryFee);
        console2.log("  hook fee -> vault (wei)  ", t.hookProjectFee);
        console2.log("  hook fee -> Programmable ", t.hookProgrammableFee);
        console2.log("  router call gas          ", t.gas);
    }

    // ---------------------------------------------------------------- tests

    /// The builder reproduces Programmable's server-prepared routed buy byte-for-byte.
    function test_0_builder_matches_programmable_prepare_endpoint() public pure {
        // POST /api/swap/ethereum/prepare, Temo 0x0f8B..1A2D, side buy, amountIn 0.1 ETH, slippage 300, deadline 1792028822
        // response fee.mode = programmable_routed, routedRateBps 30, platformFeeAmount 300000000000000
        PoolKey memory temo = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(0x0f8B5B82A8A62137e4eA563A3709fE4Ca1fF1A2D),
            8388608,
            1,
            IHooks(0x530f27fC312DB92b4f47A4CF3C5305e6110b20cC)
        );
        bytes memory mine = _calldata(temo, true, 100000000000000000, 1398916684436876393039694, 1792028822);
        assertEq(keccak256(mine), keccak256(TEMO_PREPARED_BUY), "builder != Programmable prepare calldata");
    }

    /// Initial-buy path: the dev buy inside the launch transaction pays the hook fee (to the vault) and NO
    /// Programmable fee anywhere (no router involved, hook share 0).
    function test_1_initial_buy_path() public view {
        console2.log("initial buy (launch tx, 0.06 ETH)");
        console2.log("  dev tokens               ", initDevTokens);
        console2.log("  treasury platform fee    ", initTreasuryDelta);
        console2.log("  hook fee -> vault (wei)  ", initHookProjectFee);
        console2.log("  hook fee -> Programmable ", initProgrammableAccrued);
        assertEq(initTreasuryDelta, 0);
        assertEq(initProgrammableAccrued, 0);
        assertEq(initHookProjectFee, DEV_BUY * 5 / 100, "5% launch fee to the vault");
        assertLe(initDevTokens, MAX_BUY);
    }

    /// Routed buy in the launch window: exactly one 0.30% platform fee (router TRANSFER), hook 5% all to the vault.
    function test_2_routed_buy_launch_window() public {
        Trade memory t = _trade(true, 0.05 ether, "routed buy at launch (0.05 ETH, hook 5%)");
        assertEq(t.treasuryFee, 0.05 ether * 30 / 10_000, "exactly one 0.30% of the funded ETH");
        assertEq(t.spent, 0.05 ether);
        uint256 net = 0.05 ether - t.treasuryFee;
        assertEq(t.hookProjectFee, net * 5 / 100, "hook 5% of the swapped ETH, all to the vault");
    }

    /// Routed sell: exactly one 0.30% platform fee (router TAKE_PORTION of the gross ETH credit).
    function test_3_routed_sell_launch_window() public {
        _trade(true, 0.05 ether, "setup buy");
        uint256 amt = token.balanceOf(alice) / 2;
        Trade memory t = _trade(false, amt, "routed sell at launch (half the bag, hook 5%)");
        uint256 gross = t.received + t.treasuryFee; // router's ETH credit after the hook fee
        assertEq(t.treasuryFee, gross * 30 / 10_000, "exactly one 0.30% of the gross ETH output credit");
        assertEq(t.spent, amt);
        assertGt(t.hookProjectFee, 0);
        // hook 5%: credit = poolOut - hookFee, hookFee = 5% of poolOut  =>  hookFee ~= credit * 5/95
        assertApproxEqAbs(t.hookProjectFee, gross * 5 / 95, 2);
    }

    /// After the 5-minute decay: 3% hook fee, still exactly one 0.30% platform fee each way.
    function test_4_routed_buy_and_sell_after_decay() public {
        vm.warp(block.timestamp + 301);
        Trade memory b = _trade(true, 1 ether, "routed buy after decay (1 ETH, hook 3%)");
        assertEq(b.treasuryFee, 1 ether * 30 / 10_000);
        assertEq(b.hookProjectFee, (1 ether - b.treasuryFee) * 3 / 100);
        uint256 amt = token.balanceOf(alice);
        Trade memory s = _trade(false, amt, "routed sell after decay (whole bag, hook 3%)");
        uint256 gross = s.received + s.treasuryFee;
        assertEq(s.treasuryFee, gross * 30 / 10_000);
        assertApproxEqAbs(s.hookProjectFee, gross * 3 / 97, 2);
    }

    bytes constant TEMO_PREPARED_BUY = hex"3593564c000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000006ad03096000000000000000000000000000000000000000000000000000000000000000305100400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000044000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d88539d3c4c460136a733a3fd60cf6bf269079da000000000000000000000000000000000000000000000000000110d9316ec0000000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003060c0f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f8b5b82a8a62137e4ea563a3709fe4ca1ff1a2d00000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000530f27fc312db92b4f47a4cf3c5305e6110b20cc00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000162349f2c1b400000000000000000000000000000000000000000000001283b6ce84d172825c74e00000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000162349f2c1b400000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000f8b5b82a8a62137e4ea563a3709fe4ca1ff1a2d00000000000000000000000000000000000000000001283b6ce84d172825c74e0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000";
}
