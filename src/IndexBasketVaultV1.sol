// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IWETH9 {
    function deposit() external payable;
}

interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IFeeHookClaim {
    function projectFeeOwner() external view returns (address);
    function projectFeesAccrued() external view returns (uint256);
    function claimProjectFees(address recipient) external returns (uint256);
}

interface IIndexRewardToken {
    function distributePoints(uint256 points) external;
    function consumePoints(address account) external returns (uint256);
    function withdrawablePointsOf(address account) external view returns (uint256);
    function rewardVault() external view returns (address);
}

/// @title IndexBasketVaultV1
/// @notice Holder-reward vault of an index token launched through Programmable. It is the hook's project-fee owner:
///         `harvest` pulls the project share of the hook's ETH fees, keeps an immutable dev share, converts the rest
///         into a fixed basket of reward assets (fixed weights, fixed routes) and credits the converted ETH amount to
///         holders as reward points in the token. Holders redeem their points for their pro-rata share of every
///         basket asset the vault holds (`claim`).
/// @dev Trust surface, all fixed at deployment:
///      - routes, weights, dev wallet and dev share are immutable; there is no owner, no withdraw, no sweep,
///        no arbitrary call. Basket assets can only leave through `claim` (to holders) and dev ETH only through
///        `claimDev` (to the immutable dev wallet).
///      - the keeper can only trigger `harvest` with its own minimum-output protection; it can hand the role to a new
///        address or renounce it. It can never receive vault funds.
///      - if no harvest happened for PUBLIC_HARVEST_DELAY, anyone may call `publicHarvest`, which skips all swaps and
///        converts the ETH into the WETH leg only (no slippage surface), so rewards keep flowing without the keeper.
contract IndexBasketVaultV1 is IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    enum RouteKind {
        WRAP_WETH, // asset == WETH, just wrap ETH
        UNISWAP_V3, // ETH -> WETH -> asset through one Uniswap v3 WETH/asset pool
        UNISWAP_V4_NATIVE // ETH -> asset through one Uniswap v4 native-ETH pool (currency0 = ETH)
    }

    struct RewardRoute {
        address asset;
        RouteKind kind;
        uint16 weightBps;
        address v3Pool; // UNISWAP_V3 only
        uint24 v4Fee; // UNISWAP_V4_NATIVE only
        int24 v4TickSpacing; // UNISWAP_V4_NATIVE only
        address v4Hooks; // UNISWAP_V4_NATIVE only
    }

    uint256 public constant MAX_ROUTES = 8;
    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_DEV_SHARE_BPS = 5_000;
    address public constant CANONICAL_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant CANONICAL_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes4 private constant SWAP_UNLOCK_MAGIC = bytes4(keccak256("INDEX_BASKET_VAULT_V1_SWAP"));

    IPoolManager public immutable poolManager;
    address public immutable weth;
    /// @notice Launch initializer; the only address that may bind the token and hook, exactly once.
    address public immutable binder;
    address public immutable devWallet;
    uint16 public immutable devShareBps;
    uint256 public immutable minHarvestWei;
    uint256 public immutable publicHarvestDelay;

    address public keeper;
    address public pendingKeeper;
    address public token;
    address public hook;
    bool public bound;

    RewardRoute[] private _routes;

    /// @notice Reward points (wei of ETH converted into the basket) credited to holders and not yet redeemed.
    uint256 public outstandingPoints;
    uint256 public totalRewardEth;
    uint256 public devOwed;
    uint256 public totalDevEth;
    uint256 public lastHarvestAt;
    uint256 public harvestCount;

    address private _expectedV3Pool;

    error AlreadyBound();
    error BadRoute(uint256 index);
    error BadWeights(uint256 sum);
    error DeadlineExpired();
    error InsufficientOutput(uint256 index, uint256 out, uint256 minimum);
    error InvalidBinding();
    error InvalidDevShare(uint16 bps);
    error NotBound();
    error NothingToClaim();
    error NothingToHarvest(uint256 available, uint256 minimum);
    error PublicHarvestTooEarly(uint256 availableAt);
    error TransferFailed();
    error Unauthorized(address caller);
    error UnexpectedCallback();
    error ZeroAddress();

    event Bound(address indexed token, address indexed hook);
    event Harvested(
        address indexed caller, bool indexed publicMode, uint256 grossEth, uint256 devEth, uint256 rewardEth, uint256[] amountsOut
    );
    event Claimed(address indexed account, address indexed recipient, uint256 points, uint256[] amounts);
    event DevClaimed(address indexed devWallet, uint256 amount);
    event KeeperTransferStarted(address indexed keeper, address indexed pendingKeeper);
    event KeeperChanged(address indexed previousKeeper, address indexed newKeeper);

    constructor(
        IPoolManager poolManager_,
        address weth_,
        address binder_,
        address keeper_,
        address devWallet_,
        uint16 devShareBps_,
        uint256 minHarvestWei_,
        uint256 publicHarvestDelay_,
        RewardRoute[] memory routes_
    ) {
        if (address(poolManager_) != CANONICAL_POOL_MANAGER || weth_ != CANONICAL_WETH) revert InvalidBinding();
        if (binder_ == address(0) || keeper_ == address(0) || devWallet_ == address(0)) revert ZeroAddress();
        if (devShareBps_ > MAX_DEV_SHARE_BPS) revert InvalidDevShare(devShareBps_);
        if (routes_.length == 0 || routes_.length > MAX_ROUTES) revert BadRoute(routes_.length);
        uint256 sum;
        bool hasWeth;
        for (uint256 i; i < routes_.length; ++i) {
            RewardRoute memory r = routes_[i];
            if (r.asset == address(0) || r.weightBps == 0) revert BadRoute(i);
            for (uint256 j; j < i; ++j) {
                if (routes_[j].asset == r.asset) revert BadRoute(i);
            }
            if (r.kind == RouteKind.WRAP_WETH) {
                if (r.asset != weth_) revert BadRoute(i);
                hasWeth = true;
            } else if (r.kind == RouteKind.UNISWAP_V3) {
                if (r.v3Pool == address(0)) revert BadRoute(i);
            } else if (r.v4TickSpacing < TickMath.MIN_TICK_SPACING || r.v4TickSpacing > TickMath.MAX_TICK_SPACING) {
                revert BadRoute(i);
            }
            sum += r.weightBps;
            _routes.push(r);
        }
        if (sum != BPS) revert BadWeights(sum);
        if (!hasWeth) revert BadRoute(type(uint256).max); // the public fallback needs a WETH leg
        poolManager = poolManager_;
        weth = weth_;
        binder = binder_;
        keeper = keeper_;
        devWallet = devWallet_;
        devShareBps = devShareBps_;
        minHarvestWei = minHarvestWei_;
        publicHarvestDelay = publicHarvestDelay_;
    }

    receive() external payable { }

    // ─────────────────────────────── launch binding ───────────────────────────────

    /// @notice Called once by the launch initializer inside the launch transaction.
    function bind(address token_, address hook_) external {
        if (msg.sender != binder) revert Unauthorized(msg.sender);
        if (bound) revert AlreadyBound();
        if (
            token_ == address(0) || hook_ == address(0) || IIndexRewardToken(token_).rewardVault() != address(this)
                || IFeeHookClaim(hook_).projectFeeOwner() != address(this)
        ) revert InvalidBinding();
        bound = true;
        token = token_;
        hook = hook_;
        lastHarvestAt = block.timestamp;
        emit Bound(token_, hook_);
    }

    // ─────────────────────────────── views ───────────────────────────────

    function routeCount() external view returns (uint256) {
        return _routes.length;
    }

    function route(uint256 index) external view returns (RewardRoute memory) {
        return _routes[index];
    }

    function routes() external view returns (RewardRoute[] memory) {
        return _routes;
    }

    /// @notice ETH that the next harvest would process (hook project fees + ETH already in the vault minus dev ETH).
    function harvestableEth() public view returns (uint256) {
        uint256 accrued = bound ? IFeeHookClaim(hook).projectFeesAccrued() : 0;
        return accrued + address(this).balance - devOwed;
    }

    function basketBalances() public view returns (address[] memory assets, uint256[] memory balances) {
        uint256 n = _routes.length;
        assets = new address[](n);
        balances = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            assets[i] = _routes[i].asset;
            balances[i] = IERC20(assets[i]).balanceOf(address(this));
        }
    }

    /// @notice What `claim` would pay `account` right now, per basket asset (same order as `routes()`).
    function pendingRewards(address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, uint256 points)
    {
        (assets, amounts) = basketBalances();
        points = bound ? IIndexRewardToken(token).withdrawablePointsOf(account) : 0;
        uint256 outstanding = outstandingPoints;
        for (uint256 i; i < amounts.length; ++i) {
            amounts[i] = (points == 0 || outstanding == 0) ? 0 : (amounts[i] * points) / outstanding;
        }
    }

    function publicHarvestAvailableAt() public view returns (uint256) {
        return lastHarvestAt + publicHarvestDelay;
    }

    // ─────────────────────────────── harvest ───────────────────────────────

    /// @notice Keeper-only. Pulls hook fees, keeps the dev share, swaps the rest into the basket and credits holders.
    /// @param minAmountsOut minimum output per route (same order as `routes()`). The keeper script previews the exact
    ///        outputs with an eth_call of this function (all minimums 0) and sends the real call with a slippage cut.
    function harvest(uint256[] calldata minAmountsOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        if (msg.sender != keeper) revert Unauthorized(msg.sender);
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (minAmountsOut.length != _routes.length) revert BadRoute(minAmountsOut.length);
        return _harvest(minAmountsOut, false);
    }

    /// @notice Anyone, once no harvest happened for `publicHarvestDelay`. Converts everything into the WETH leg only.
    function publicHarvest() external nonReentrant returns (uint256[] memory amountsOut) {
        if (block.timestamp < publicHarvestAvailableAt()) revert PublicHarvestTooEarly(publicHarvestAvailableAt());
        return _harvest(new uint256[](0), true);
    }

    function _harvest(uint256[] memory minAmountsOut, bool publicMode) private returns (uint256[] memory amountsOut) {
        if (!bound) revert NotBound();
        if (IFeeHookClaim(hook).projectFeesAccrued() != 0) IFeeHookClaim(hook).claimProjectFees(address(this));
        uint256 gross = address(this).balance - devOwed;
        if (gross == 0 || gross < minHarvestWei) revert NothingToHarvest(gross, minHarvestWei);

        uint256 devEth = (gross * devShareBps) / BPS;
        uint256 rewardEth = gross - devEth;
        devOwed += devEth;
        totalDevEth += devEth;

        uint256 n = _routes.length;
        amountsOut = new uint256[](n);
        if (publicMode) {
            IWETH9(weth).deposit{ value: rewardEth }();
            for (uint256 i; i < n; ++i) {
                if (_routes[i].kind == RouteKind.WRAP_WETH) amountsOut[i] = rewardEth;
            }
        } else {
            uint256[] memory amountsIn = new uint256[](n);
            uint256 assigned;
            uint256 v4Total;
            for (uint256 i; i < n; ++i) {
                amountsIn[i] = i == n - 1 ? rewardEth - assigned : (rewardEth * _routes[i].weightBps) / BPS;
                assigned += amountsIn[i];
                if (_routes[i].kind == RouteKind.UNISWAP_V4_NATIVE) v4Total += amountsIn[i];
            }
            uint256 wethNeeded = rewardEth - v4Total;
            if (wethNeeded != 0) IWETH9(weth).deposit{ value: wethNeeded }();
            for (uint256 i; i < n; ++i) {
                RewardRoute memory r = _routes[i];
                if (amountsIn[i] == 0) continue;
                if (r.kind == RouteKind.WRAP_WETH) amountsOut[i] = amountsIn[i];
                else if (r.kind == RouteKind.UNISWAP_V3) amountsOut[i] = _swapV3(r, amountsIn[i]);
            }
            if (v4Total != 0) {
                bytes memory result =
                    poolManager.unlock(abi.encode(SWAP_UNLOCK_MAGIC, amountsIn));
                uint256[] memory v4Out = abi.decode(result, (uint256[]));
                for (uint256 i; i < n; ++i) {
                    if (_routes[i].kind == RouteKind.UNISWAP_V4_NATIVE) amountsOut[i] = v4Out[i];
                }
            }
            for (uint256 i; i < n; ++i) {
                if (amountsOut[i] < minAmountsOut[i]) revert InsufficientOutput(i, amountsOut[i], minAmountsOut[i]);
            }
        }

        outstandingPoints += rewardEth;
        totalRewardEth += rewardEth;
        lastHarvestAt = block.timestamp;
        ++harvestCount;
        IIndexRewardToken(token).distributePoints(rewardEth);
        emit Harvested(msg.sender, publicMode, gross, devEth, rewardEth, amountsOut);
    }

    function _swapV3(RewardRoute memory r, uint256 amountIn) private returns (uint256 amountOut) {
        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(r.v3Pool);
        bool zeroForOne = pool.token0() == weth;
        if ((zeroForOne ? pool.token1() : pool.token0()) != r.asset) revert BadRoute(type(uint256).max - 1);
        _expectedV3Pool = address(pool);
        (int256 a0, int256 a1) = pool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            ""
        );
        _expectedV3Pool = address(0);
        amountOut = uint256(-(zeroForOne ? a1 : a0));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _expectedV3Pool || _expectedV3Pool == address(0)) revert UnexpectedCallback();
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(weth).safeTransfer(msg.sender, owed);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_reentrancyGuardEntered()) revert UnexpectedCallback();
        (bytes4 magic, uint256[] memory amountsIn) = abi.decode(data, (bytes4, uint256[]));
        if (magic != SWAP_UNLOCK_MAGIC) revert UnexpectedCallback();
        uint256 n = _routes.length;
        uint256[] memory out = new uint256[](n);
        uint256 ethOwed;
        for (uint256 i; i < n; ++i) {
            RewardRoute memory r = _routes[i];
            if (r.kind != RouteKind.UNISWAP_V4_NATIVE || amountsIn[i] == 0) continue;
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(r.asset),
                fee: r.v4Fee,
                tickSpacing: r.v4TickSpacing,
                hooks: IHooks(r.v4Hooks)
            });
            BalanceDelta d = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(amountsIn[i]),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            if (d.amount0() >= 0 || d.amount1() <= 0) revert InsufficientOutput(i, 0, 1);
            ethOwed += uint256(-int256(d.amount0()));
            out[i] = uint256(int256(d.amount1()));
            poolManager.take(Currency.wrap(r.asset), address(this), out[i]);
        }
        poolManager.settle{ value: ethOwed }();
        return abi.encode(out);
    }

    // ─────────────────────────────── claims ───────────────────────────────

    /// @notice Redeems all of the caller's reward points for its pro-rata share of every basket asset.
    function claim() external nonReentrant returns (uint256[] memory amounts) {
        return _claim(msg.sender, msg.sender);
    }

    /// @notice Same as `claim`, paid to `account` itself. Lets anyone (e.g. a keeper) push rewards to holders.
    function claimFor(address account) external nonReentrant returns (uint256[] memory amounts) {
        return _claim(account, account);
    }

    function _claim(address account, address recipient) private returns (uint256[] memory amounts) {
        if (!bound) revert NotBound();
        uint256 outstanding = outstandingPoints;
        uint256 points = IIndexRewardToken(token).consumePoints(account);
        if (points == 0 || outstanding == 0) revert NothingToClaim();
        if (points > outstanding) points = outstanding;
        outstandingPoints = outstanding - points;
        uint256 n = _routes.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            IERC20 asset = IERC20(_routes[i].asset);
            amounts[i] = (asset.balanceOf(address(this)) * points) / outstanding;
            if (amounts[i] != 0) asset.safeTransfer(recipient, amounts[i]);
        }
        emit Claimed(account, recipient, points, amounts);
    }

    /// @notice Pays the accrued dev share (ETH) to the immutable dev wallet. Callable by anyone.
    function claimDev() external nonReentrant returns (uint256 amount) {
        amount = devOwed;
        if (amount == 0) revert NothingToClaim();
        devOwed = 0;
        (bool ok,) = devWallet.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit DevClaimed(devWallet, amount);
    }

    // ─────────────────────────────── keeper role ───────────────────────────────

    function transferKeeper(address newKeeper) external {
        if (msg.sender != keeper) revert Unauthorized(msg.sender);
        pendingKeeper = newKeeper;
        emit KeeperTransferStarted(keeper, newKeeper);
    }

    function acceptKeeper() external {
        if (msg.sender != pendingKeeper || msg.sender == address(0)) revert Unauthorized(msg.sender);
        emit KeeperChanged(keeper, msg.sender);
        keeper = msg.sender;
        pendingKeeper = address(0);
    }

    /// @notice Permanently removes the keeper; from then on only `publicHarvest` (WETH leg) can run.
    function renounceKeeper() external {
        if (msg.sender != keeper) revert Unauthorized(msg.sender);
        emit KeeperChanged(keeper, address(0));
        keeper = address(0);
        pendingKeeper = address(0);
    }
}
