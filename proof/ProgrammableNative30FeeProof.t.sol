// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { DecayingVolumeFeeHookV1 } from "../src/DecayingVolumeFeeHookV1.sol";
import { IndexRewardTokenV1 } from "../src/IndexRewardTokenV1.sol";
import { IndexBasketVaultV1 } from "../src/IndexBasketVaultV1.sol";
import { IndexSeededLaunchInitializerV1 } from "../src/IndexSeededLaunchInitializerV1.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC6909Balance {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

/// Same layout as v4-periphery IV4Router.ExactInputSingleParams (verified router source).
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// A bare PoolManager router (no Universal Router at all): stands in for "any other router".
contract BareRouter is IUnlockCallback {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    PoolKey key;

    constructor(PoolKey memory k) {
        key = k;
    }

    function buy() external payable returns (uint256 out) {
        out = abi.decode(PM.unlock(abi.encode(msg.sender, true, msg.value)), (uint256));
    }

    function sell(uint256 amount) external returns (uint256 out) {
        IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount);
        out = abi.decode(PM.unlock(abi.encode(msg.sender, false, amount)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM));
        (address user, bool isBuy, uint256 amount) = abi.decode(data, (address, bool, uint256));
        BalanceDelta d = PM.swap(
            key,
            SwapParams({
                zeroForOne: isBuy,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        if (isBuy) {
            PM.settle{ value: amount }();
            uint256 out = uint256(int256(d.amount1()));
            PM.take(key.currency1, user, out);
            return abi.encode(out);
        } else {
            PM.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(PM), amount);
            PM.settle();
            uint256 out = uint256(int256(d.amount0()));
            PM.take(key.currency0, user, out);
            return abi.encode(out);
        }
    }

    receive() external payable { }
}

/// PIDX fee proof for Programmable's pool-fee (native30-style) integration.
///
/// The hook DecayingVolumeFeeHookV1 enforces PROGRAMMABLE_HUNDREDTHS_OF_BIP = 3000 (0.30%) of the gross native leg of
/// EVERY swap in the exact PIDX pool, whoever routes it, the launch transaction's initial buy included. The share accrues
/// to PROGRAMMABLE_FEE_OWNER = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da as backed PoolManager native ERC-6909 claims
/// held by the hook, and claimProgrammableFees() is permissionless and always pays that fixed address.
///
/// Programmable's route = UniversalRouter 0xd92A36B0000531EF3063dEd4De20A0783308446C with calldata built exactly like
/// programmable.market's builder. For a pool-enforced (native30) pool the builder sends the full amount into
/// V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL] + SWEEP, with NO router TRANSFER/TAKE_PORTION (checked byte-for-byte
/// against Programmable's own prepare response for brownies). On that route PIDX pays exactly one 0.30% platform charge.
contract ProgrammableNative30FeeProofTest is Test {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant FACTORY = 0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887;
    address constant PROGRAMMABLE_ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    address constant UNISWAP_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant TREASURY = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address constant MSG_SENDER = address(1);
    uint256 constant RATE = 3000; // hundredths of a bip
    uint256 constant DEN = 1_000_000;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CLAUS = 0x1b54E762aa34CF6E28E9C082F2848e28E45DA6b8;
    address constant V4 = 0x7987f03462200b3D8A072E02C89A8A41dCB124EE;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant WBTC_WETH_V3 = 0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0;
    address constant LINK_WETH_V3 = 0xa6Cc3C2531FdaA6Ae1A3CA84c2855806728693e8;

    address constant LAUNCHER = 0x15a80CDE1f28C9E1a29c39780e7623f84560180b;
    uint256 constant DEV_BUY = 0.06 ether;
    uint256 constant MAX_BUY = 30_000_000e18;
    int24 constant TICK_UPPER = 200280;
    int24 constant TICK_LOWER = -887220;

    address trader = makeAddr("pidx-native30-proof-trader");
    address anyone = makeAddr("pidx-native30-proof-claimer");

    IndexSeededLaunchInitializerV1 init;
    IndexRewardTokenV1 token;
    IndexBasketVaultV1 vault;
    DecayingVolumeFeeHookV1 hook;
    BareRouter bare;
    PoolKey key;

    uint256 initTreasuryTransfer;
    uint256 initProgrammable;
    uint256 initProject;
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
        bare = new BareRouter(key);

        // initial-buy path: the launch transaction itself (graph factory -> initializer -> seeded pool + 0.06 ETH dev buy)
        DecayingVolumeFeeHookV1.FeeSchedule memory s = DecayingVolumeFeeHookV1.FeeSchedule(50_000, 30_000, 300);
        uint256 t0 = TREASURY.balance;
        vm.deal(FACTORY, 1 ether);
        vm.prank(FACTORY);
        init.initialize{ value: DEV_BUY }(address(token), hookAddr, payable(address(vault)), LAUNCHER, 1, s, s);
        initTreasuryTransfer = TREASURY.balance - t0;
        initProgrammable = hook.programmableFeesAccrued();
        initProject = hook.projectFeesAccrued();
        initDevTokens = token.balanceOf(LAUNCHER);

        require(trader.code.length == 0 && anyone.code.length == 0, "plain EOAs");
        vm.deal(trader, 100 ether);
    }

    // ---------------------------------------------------------------- calldata builder (mirrors programmable.market fc)

    function _calldata(PoolKey memory k, bool buy, uint256 amountIn, uint256 minOut, uint256 deadline, bool routed)
        internal
        pure
        returns (bytes memory)
    {
        address tok = Currency.unwrap(k.currency1);
        uint256 fee = routed && buy ? amountIn * 30 / 10_000 : 0;
        uint256 net = amountIn - fee;
        bool portion = routed && !buy;

        bytes memory actions = portion
            ? abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x10), uint8(0x0f))
            : abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](portion ? 4 : 3);
        params[0] = abi.encode(ExactInputSingleParams(k, buy, uint128(net), uint128(minOut), ""));
        params[1] = abi.encode(buy ? address(0) : tok, net);
        if (portion) params[2] = abi.encode(address(0), TREASURY, uint256(30));
        params[portion ? 3 : 2] = abi.encode(buy ? tok : address(0), minOut);

        bytes memory commands;
        bytes[] memory inputs;
        if (fee != 0) {
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

    // ---------------------------------------------------------------- trade harness

    struct Trade {
        uint256 treasuryTransfer; // ETH sent straight to the treasury during the trade (router fees)
        uint256 programmable; // hook accrual to PROGRAMMABLE_FEE_OWNER
        uint256 project; // hook accrual to the project vault
        uint256 gross; // gross native leg of the swap
        uint256 received;
        uint256 gas;
    }

    function _urTrade(address router, bool buy, uint256 amountIn, uint256 minOut, bool routed) internal returns (Trade memory t) {
        bytes memory data = _calldata(key, buy, amountIn, minOut, block.timestamp + 240, routed);
        uint256 tre = TREASURY.balance;
        uint256 pq = hook.programmableFeesAccrued();
        uint256 pp = hook.projectFeesAccrued();
        uint256 eth = trader.balance;
        uint256 bal = token.balanceOf(trader);
        vm.startPrank(trader);
        if (!buy) {
            token.approve(PERMIT2, amountIn);
            IPermit2(PERMIT2).approve(address(token), router, uint160(amountIn), uint48(block.timestamp + 3840));
        }
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = router.call{ value: buy ? amountIn : 0 }(data);
        t.gas = g - gasleft();
        vm.stopPrank();
        if (!ok) {
            assembly { revert(add(ret, 32), mload(ret)) }
        }
        t.treasuryTransfer = TREASURY.balance - tre;
        t.programmable = hook.programmableFeesAccrued() - pq;
        t.project = hook.projectFeesAccrued() - pp;
        t.received = buy ? token.balanceOf(trader) - bal : trader.balance - eth;
        // gross native leg: buy = ETH that entered the hook/pool; sell = ETH the pool paid out before fees
        t.gross = buy ? amountIn - t.treasuryTransfer : t.received + t.treasuryTransfer + t.programmable + t.project;
        assertEq(router.balance, 0, "router keeps no ETH");
        assertEq(token.balanceOf(router), 0, "router keeps no PIDX");
    }

    function _quoted(address router, bool buy, uint256 amountIn, bool routed) internal returns (Trade memory t) {
        uint256 snap = vm.snapshotState();
        uint256 q = _urTrade(router, buy, amountIn, 1, routed).received;
        vm.revertToState(snap);
        uint256 minOut = q * 9700 / 10_000; // 300 bps slippage, as Programmable's prepare endpoint
        t = _urTrade(router, buy, amountIn, minOut, routed);
        assertGe(t.received, minOut);
    }

    function _assertOnePlatformCharge(Trade memory t, uint256 totalRate) internal pure {
        // exactly 0.30% of the gross native leg (floor, with the kernel's carried sub-wei remainder: at most +1 wei)
        uint256 floorFee = t.gross * RATE / DEN;
        assertGe(t.programmable, floorFee, "platform >= 0.30%");
        assertLe(t.programmable, floorFee + 1, "platform <= 0.30% + 1 wei");
        assertEq(t.treasuryTransfer, 0, "no second (router) platform charge");
        // the project gets the rest of the disclosed total
        uint256 total = t.programmable + t.project;
        assertApproxEqAbs(total, t.gross * totalRate / DEN, 2, "total = disclosed schedule");
    }

    function _log(string memory label, Trade memory t) internal pure {
        console2.log(label);
        console2.log("  gross native leg (wei)        ", t.gross);
        console2.log("  received (wei)                ", t.received);
        console2.log("  hook -> Programmable (wei)    ", t.programmable);
        console2.log("  hook -> project vault (wei)   ", t.project);
        console2.log("  router transfer to treasury   ", t.treasuryTransfer);
        console2.log("  gas                           ", t.gas);
    }

    function _assertBacked() internal view {
        uint256 claims = IERC6909Balance(address(PM)).balanceOf(address(hook), 0);
        assertEq(hook.totalQuoteFeesAccrued(), hook.programmableFeesAccrued() + hook.projectFeesAccrued());
        assertGe(claims, hook.totalQuoteFeesAccrued(), "every accrued wei is backed by PoolManager ETH claims");
    }

    // ---------------------------------------------------------------- tests

    /// Our builder reproduces Programmable's prepare endpoint byte-for-byte, for both route modes.
    function test_0_builder_matches_programmable_prepare() public pure {
        // pool_enforced_native30 (brownies): POST /api/swap/ethereum/prepare, buy 0.01 ETH, deadline 1792028788
        PoolKey memory brownies = PoolKey(Currency.wrap(address(0)), Currency.wrap(0x72321bCb82039fF421B55A671e4e9d28b8cad53F), 0, 60, IHooks(0x40EB8C2eca9Bc0B62c800714D48e8fEAB0AA3fFf));
        assertEq(keccak256(_calldata(brownies, true, 10000000000000000, 160001548326269140846463, 1792028788, false)), keccak256(BROWNIES_NATIVE30_BUY));
        // programmable_routed (Temo): buy 0.1 ETH, deadline 1792028822
        PoolKey memory temo = PoolKey(Currency.wrap(address(0)), Currency.wrap(0x0f8B5B82A8A62137e4eA563A3709fE4Ca1fF1A2D), 8388608, 1, IHooks(0x530f27fC312DB92b4f47A4CF3C5305e6110b20cC));
        assertEq(keccak256(_calldata(temo, true, 100000000000000000, 1398916684436876393039694, 1792028822, true)), keccak256(TEMO_ROUTED_BUY));
    }

    /// Initial buy: the dev buy inside the launch transaction pays the 0.30% Programmable share to the hook ledger.
    function test_1_initial_buy() public view {
        console2.log("initial buy (launch tx, 0.06 ETH, total fee 5%)");
        console2.log("  dev tokens                    ", initDevTokens);
        console2.log("  hook -> Programmable (wei)    ", initProgrammable);
        console2.log("  hook -> project vault (wei)   ", initProject);
        console2.log("  router transfer to treasury   ", initTreasuryTransfer);
        assertEq(initProgrammable, DEV_BUY * RATE / DEN, "0.30% of 0.06 ETH = 0.00018 ETH");
        assertEq(initProject, DEV_BUY * (50_000 - RATE) / DEN, "4.70% to the vault");
        assertEq(initTreasuryTransfer, 0);
        assertEq(hook.PROGRAMMABLE_HUNDREDTHS_OF_BIP(), 3000);
        assertEq(hook.PROGRAMMABLE_FEE_OWNER(), TREASURY);
        _assertBacked();
    }

    /// Programmable's route (native30 shape): buy and sell in the launch window, exactly one 0.30% each.
    function test_2_programmable_route_launch_window() public {
        Trade memory b = _quoted(PROGRAMMABLE_ROUTER, true, 0.05 ether, false);
        _log("Programmable route buy, 0.05 ETH, launch window (total 5%)", b);
        _assertOnePlatformCharge(b, 50_000);
        Trade memory s = _quoted(PROGRAMMABLE_ROUTER, false, token.balanceOf(trader) / 2, false);
        _log("Programmable route sell, half the bag, launch window (total 5%)", s);
        _assertOnePlatformCharge(s, 50_000);
        _assertBacked();
    }

    /// After the 300 s decay: total 3%, still exactly one 0.30% platform charge each way.
    function test_3_programmable_route_after_decay() public {
        vm.warp(block.timestamp + 301);
        Trade memory b = _quoted(PROGRAMMABLE_ROUTER, true, 1 ether, false);
        _log("Programmable route buy, 1 ETH, after decay (total 3%)", b);
        _assertOnePlatformCharge(b, 30_000);
        Trade memory s = _quoted(PROGRAMMABLE_ROUTER, false, token.balanceOf(trader), false);
        _log("Programmable route sell, whole bag, after decay (total 3%)", s);
        _assertOnePlatformCharge(s, 30_000);
        _assertBacked();
    }

    /// Other routers pay the same enforced 0.30%: Uniswap's public Universal Router and a bare PoolManager router.
    function test_4_other_routers_pay_too() public {
        vm.warp(block.timestamp + 301);
        Trade memory b = _quoted(UNISWAP_ROUTER, true, 0.5 ether, false);
        _log("Uniswap Universal Router buy, 0.5 ETH", b);
        _assertOnePlatformCharge(b, 30_000);
        Trade memory s = _quoted(UNISWAP_ROUTER, false, token.balanceOf(trader), false);
        _log("Uniswap Universal Router sell, whole bag", s);
        _assertOnePlatformCharge(s, 30_000);

        uint256 pq = hook.programmableFeesAccrued();
        vm.prank(trader);
        bare.buy{ value: 0.5 ether }();
        uint256 bareBuy = hook.programmableFeesAccrued() - pq;
        assertGe(bareBuy, 0.5 ether * RATE / DEN);
        assertLe(bareBuy, 0.5 ether * RATE / DEN + 1);
        uint256 amt = token.balanceOf(trader);
        pq = hook.programmableFeesAccrued();
        uint256 eth = trader.balance;
        vm.startPrank(trader);
        token.approve(address(bare), amt);
        bare.sell(amt);
        vm.stopPrank();
        uint256 bareSell = hook.programmableFeesAccrued() - pq;
        assertGt(bareSell, 0);
        console2.log("bare PoolManager router: buy 0.5 ETH -> Programmable", bareBuy);
        console2.log("bare PoolManager router: sell -> Programmable       ", bareSell);
        console2.log("  (sell received)                                     ", trader.balance - eth);
        _assertBacked();
    }

    /// The fixed recipient is actually paid: anyone triggers the claim, all of it goes to the treasury.
    function test_5_permissionless_claim_pays_treasury() public {
        _quoted(PROGRAMMABLE_ROUTER, true, 0.05 ether, false);
        _quoted(PROGRAMMABLE_ROUTER, false, token.balanceOf(trader), false);
        uint256 accrued = hook.programmableFeesAccrued();
        uint256 claimsBefore = IERC6909Balance(address(PM)).balanceOf(address(hook), 0);
        uint256 tre = TREASURY.balance;
        uint256 callerEth = anyone.balance;
        vm.prank(anyone);
        uint256 paid = hook.claimProgrammableFees();
        console2.log("claim by an unrelated address: paid to treasury (wei)", paid);
        assertEq(paid, accrued);
        assertEq(TREASURY.balance - tre, accrued, "treasury received exactly the accrued share");
        assertEq(anyone.balance, callerEth, "caller receives nothing");
        assertEq(hook.programmableFeesAccrued(), 0);
        assertEq(claimsBefore - IERC6909Balance(address(PM)).balanceOf(address(hook), 0), accrued, "claims burned 1:1");
        vm.expectRevert();
        hook.claimProgrammableFees(); // nothing left
        _assertBacked();
    }

    /// Why the route must be native30: if Programmable's server kept programmable_routed for this pool, its router
    /// would add a second 0.30% on top of the enforced hook share. This documents that case; it is NOT the requested route.
    function test_6_contrast_routed_mode_would_double_charge() public {
        Trade memory b = _quoted(PROGRAMMABLE_ROUTER, true, 0.05 ether, true);
        _log("contrast: programmable_routed calldata (not requested), buy 0.05 ETH", b);
        assertEq(b.treasuryTransfer, 0.05 ether * 30 / 10_000);
        assertGt(b.programmable, 0);
    }

    bytes constant BROWNIES_NATIVE30_BUY = hex"3593564c000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000006ad03074000000000000000000000000000000000000000000000000000000000000000210040000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000003a00000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003060c0f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000024000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000072321bcb82039ff421b55a671e4e9d28b8cad53f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000040eb8c2eca9bc0b62c800714d48e8feab0aa3fff0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000002386f26fc100000000000000000000000000000000000000000000000021e1b3895e34f88bc77f0000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002386f26fc10000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000072321bcb82039ff421b55a671e4e9d28b8cad53f0000000000000000000000000000000000000000000021e1b3895e34f88bc77f0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000";
    bytes constant TEMO_ROUTED_BUY = hex"3593564c000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000006ad03096000000000000000000000000000000000000000000000000000000000000000305100400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000044000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d88539d3c4c460136a733a3fd60cf6bf269079da000000000000000000000000000000000000000000000000000110d9316ec0000000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003060c0f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002400000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f8b5b82a8a62137e4ea563a3709fe4ca1ff1a2d00000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000530f27fc312db92b4f47a4cf3c5305e6110b20cc00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000162349f2c1b400000000000000000000000000000000000000000000001283b6ce84d172825c74e00000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000162349f2c1b400000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000f8b5b82a8a62137e4ea563a3709fe4ca1ff1a2d00000000000000000000000000000000000000000001283b6ce84d172825c74e0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000";
}
