// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IndexRewardTokenV1
/// @notice Fixed-supply ERC-20 minted once at deployment. The pool inventory goes to the launch initializer (which
///         seeds it as permanently locked Uniswap v4 liquidity in the launch transaction) and the optional team
///         allocation goes to the launch wallet.
///         The token also keeps holder reward accounting for the IndexBasketVaultV1: the vault reports ETH reward
///         "points" (wei of ETH it converted into the reward basket) and every holder earns them pro rata to its
///         balance. Points are redeemed for basket assets in the vault, never in this token.
/// @dev There is no owner, post-construction mint, burn hook, seizure, pause, blocklist, transfer fee, proxy or
///      upgrade surface. The only trading restriction is an optional launch-window buy limit: for
///      `launchLimitSeconds_` after deployment (= the launch block), tokens leaving the Uniswap v4 PoolManager (buys)
///      may bring a wallet's cumulative bought amount to at most `launchMaxBuy`. It switches itself off forever after
///      the window; there is no owner and nothing can extend, change or re-enable it. Sells and transfers are never
///      limited. The set of addresses that do not earn rewards (PoolManager, initializer, vault, dead address)
///      is fixed at construction and cannot be changed. Only the immutable vault can add or consume points.
///      Accounting follows the standard "magnified points per share + per-account correction" scheme, so a transfer
///      writes at most one correction per non-excluded account and rewards never need a holder loop.
contract IndexRewardTokenV1 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    /// @notice 2^128 magnification keeps rounding loss below one wei of points per account.
    uint256 public constant MAGNITUDE = 2 ** 128;
    /// @notice Points are only spread when at least this many tokens earn rewards; otherwise they are carried forward.
    ///         Bounds the per-share increment, so `magnifiedPointsPerShare * balance` can never overflow.
    uint256 public constant MIN_EARNING_SUPPLY = 1_000e18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Uniswap v4 PoolManager — holds all pool inventory; excluded from rewards.
    address public immutable poolManager;
    /// @notice Launch initializer — holds the inventory until it is seeded; excluded from rewards.
    address public immutable initializer;
    /// @notice The only contract allowed to add or consume reward points; excluded from rewards.
    address public immutable rewardVault;

    /// @notice Sum of balances that earn rewards (totalSupply minus the fixed excluded balances).
    uint256 public earningSupply;
    uint256 public magnifiedPointsPerShare;
    /// @notice Points reported while nobody (or too little supply) was earning; added to the next distribution.
    uint256 public carriedPoints;
    uint256 public totalPointsDistributed;

    /// @notice Launch-window buy limit: max cumulative tokens a wallet may receive from the PoolManager before
    ///         `launchLimitEndsAt`. Both fixed at construction; 0 end time = no limit.
    uint128 public launchMaxBuy;
    uint64 public launchLimitEndsAt;
    mapping(address account => uint256 amount) public launchBought;
    mapping(address account => int256 correction) private _pointsCorrection;
    mapping(address account => uint256 points) public consumedPoints;

    error InsufficientAllowance(uint256 available, uint256 required);
    error LaunchBuyLimitExceeded(address buyer, uint256 bought, uint256 limit);
    error InvalidLaunchLimit(uint256 maxBuy, uint256 seconds_);
    error InsufficientBalance(uint256 available, uint256 required);
    error InvalidAllocation(uint256 totalSupply, uint256 inventoryAmount);
    error UnauthorizedVault(address caller);
    error ZeroAddress();

    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event PointsDistributed(uint256 points, uint256 carriedIn, uint256 earningSupply, uint256 magnifiedPointsPerShare);
    event PointsCarried(uint256 points, uint256 earningSupply);
    event PointsConsumed(address indexed account, uint256 points);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address inventoryRecipient_,
        uint256 inventoryAmount_,
        address teamRecipient_,
        address poolManager_,
        address rewardVault_,
        uint256 launchMaxBuy_,
        uint256 launchLimitSeconds_
    ) {
        if (
            inventoryRecipient_ == address(0) || teamRecipient_ == address(0) || poolManager_ == address(0)
                || rewardVault_ == address(0)
        ) revert ZeroAddress();
        if (inventoryAmount_ == 0 || inventoryAmount_ > totalSupply_) {
            revert InvalidAllocation(totalSupply_, inventoryAmount_);
        }
        if (launchLimitSeconds_ > 3600 || (launchLimitSeconds_ != 0 && (launchMaxBuy_ == 0 || launchMaxBuy_ > totalSupply_))) {
            revert InvalidLaunchLimit(launchMaxBuy_, launchLimitSeconds_);
        }
        if (launchLimitSeconds_ != 0) {
            launchMaxBuy = uint128(launchMaxBuy_);
            launchLimitEndsAt = uint64(block.timestamp + launchLimitSeconds_);
        }
        name = name_;
        symbol = symbol_;
        totalSupply = totalSupply_;
        poolManager = poolManager_;
        initializer = inventoryRecipient_;
        rewardVault = rewardVault_;
        balanceOf[inventoryRecipient_] = inventoryAmount_;
        emit Transfer(address(0), inventoryRecipient_, inventoryAmount_);
        uint256 teamAmount = totalSupply_ - inventoryAmount_;
        if (teamAmount != 0) {
            balanceOf[teamRecipient_] += teamAmount;
            if (!isExcludedFromRewards(teamRecipient_)) earningSupply += teamAmount;
            emit Transfer(address(0), teamRecipient_, teamAmount);
        }
    }

    // ─────────────────────────────── ERC-20 ───────────────────────────────

    /// @notice Tokens `account` may still buy while the launch limit is active (type(uint256).max when inactive).
    function launchBuyRemaining(address account) external view returns (uint256) {
        if (block.timestamp >= launchLimitEndsAt) return type(uint256).max;
        uint256 b = launchBought[account];
        return b >= launchMaxBuy ? 0 : launchMaxBuy - b;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 available = allowance[from][msg.sender];
        if (available != type(uint256).max) {
            if (available < amount) revert InsufficientAllowance(available, amount);
            unchecked {
                allowance[from][msg.sender] = available - amount;
            }
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    // ─────────────────────────────── rewards ───────────────────────────────

    /// @notice Fixed at construction: these addresses hold pool inventory or protocol balances and never earn points.
    function isExcludedFromRewards(address account) public view returns (bool) {
        return account == poolManager || account == initializer || account == rewardVault || account == DEAD
            || account == address(0);
    }

    /// @notice Total points ever credited to `account` (consumed or not).
    function accumulativePointsOf(address account) public view returns (uint256) {
        uint256 shares = isExcludedFromRewards(account) ? 0 : balanceOf[account];
        int256 magnified = int256(magnifiedPointsPerShare * shares) + _pointsCorrection[account];
        return magnified <= 0 ? 0 : uint256(magnified) / MAGNITUDE;
    }

    /// @notice Points `account` can still redeem in the vault.
    function withdrawablePointsOf(address account) public view returns (uint256) {
        uint256 accumulated = accumulativePointsOf(account);
        uint256 consumed = consumedPoints[account];
        return accumulated > consumed ? accumulated - consumed : 0;
    }

    /// @notice Vault-only. Spreads `points` (wei of ETH converted into the basket) over the current earning supply.
    function distributePoints(uint256 points) external {
        if (msg.sender != rewardVault) revert UnauthorizedVault(msg.sender);
        uint256 total = points + carriedPoints;
        if (total == 0) return;
        uint256 supply = earningSupply;
        if (supply < MIN_EARNING_SUPPLY) {
            carriedPoints = total;
            emit PointsCarried(points, supply);
            return;
        }
        uint256 carriedIn = carriedPoints;
        carriedPoints = 0;
        magnifiedPointsPerShare += (total * MAGNITUDE) / supply;
        totalPointsDistributed += total;
        emit PointsDistributed(points, carriedIn, supply, magnifiedPointsPerShare);
    }

    /// @notice Vault-only. Marks all withdrawable points of `account` as consumed and returns the amount.
    function consumePoints(address account) external returns (uint256 points) {
        if (msg.sender != rewardVault) revert UnauthorizedVault(msg.sender);
        points = withdrawablePointsOf(account);
        if (points != 0) {
            consumedPoints[account] += points;
            emit PointsConsumed(account, points);
        }
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = balanceOf[from];
        if (available < amount) revert InsufficientBalance(available, amount);
        if (from == poolManager && block.timestamp < launchLimitEndsAt && !isExcludedFromRewards(to)) {
            uint256 bought = launchBought[to] + amount;
            if (bought > launchMaxBuy) revert LaunchBuyLimitExceeded(to, bought, launchMaxBuy);
            launchBought[to] = bought;
        }
        unchecked {
            balanceOf[from] = available - amount;
            balanceOf[to] += amount;
        }
        bool fromEarns = !isExcludedFromRewards(from);
        bool toEarns = !isExcludedFromRewards(to);
        if (fromEarns != toEarns || (fromEarns && from != to)) {
            int256 magnifiedDelta = int256(magnifiedPointsPerShare * amount);
            if (fromEarns) _pointsCorrection[from] += magnifiedDelta;
            if (toEarns) _pointsCorrection[to] -= magnifiedDelta;
            if (fromEarns && !toEarns) earningSupply -= amount;
            else if (!fromEarns && toEarns) earningSupply += amount;
        }
        emit Transfer(from, to, amount);
    }
}
