// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Core, IERC20} from "./Core.sol";

/// @notice HYPE/USDC x·y=k pool that closes its own gap to the HyperCore spot price by trading
/// on HyperCore, instead of leaving it to outside arbitrageurs. See docs/design.md.
/// v1: the keeper is one address, and the pool is paused while a rebalance is in flight.
///
/// Both tokens live in two places: on the EVM (`rH`, `rU`) and on the pool's own Core account
/// (read live through the spot-balance precompile, `coreH()`/`coreU()`). Both count: prices and
/// shares use the sums, so a Core fill that lands at any time (CoreWriter orders run seconds
/// later, with no settlement signal on the EVM) only moves value between the two Core balances
/// (review r3). Payouts come only from the EVM side.
///
/// HYPE is bought on Core with the USDC float, so USDC never crosses EVM -> Core (that path did
/// not credit a contract's Core account on testnet, docs/step1-bridging.md). Sales add to the
/// float; the keeper brings float to the EVM when traders or LPs need it there.
///
/// Invariant: what leaves the EVM reserves or the float for the other side stays owed to the pool
/// until it is seen there. `sendBack` fixes what is owed once (`expectH`/`expectU`) and retries
/// never lower it; `finish` only closes the round once the EVM balances reach it.
contract HedgedPool {
    enum Stage {
        Idle,
        OnCore, // sell: HYPE bridged to Core; buy: float earmarked
        Ordered, // IOC sent on the Core spot market
        Returning // Core balances sent back to the EVM
    }

    uint256 public constant FEE_BPS = 30;
    uint256 public constant SLIPPAGE_BPS = 100; // IOC limit vs Core spot price
    uint256 public constant ORDER_DELAY = 10; // seconds before `sendBack` may read the fill
    uint256 public constant STUCK_DELAY = 1 hours; // after this, an unarrived HYPE bridge may be given up
    uint256 public constant MIN_NOTIONAL = 11e6; // USDC; Core spot rejects orders under 10 USDC
    /// HYPE kept on the pool's Core account to pay for Core -> EVM sends. Funded by the keeper
    /// through `fundOps`, not by LPs; `sendBack` returns everything above it.
    uint64 public constant KEEP_HYPE_WEI = 1e6; // 0.01 HYPE
    uint256 internal constant MIN_LIQUIDITY = 1000;

    IERC20 public immutable usdc;
    address public immutable keeper;
    uint64 public immutable hypeToken; // Core token index (testnet 1105, mainnet 150)
    uint64 public immutable spotIndex; // HYPE/USDC spot pair (testnet 1035, mainnet 107)
    uint8 public immutable hypeSzDecimals; // 2

    uint256 public rH; // HYPE, 18 decimals, held on the EVM
    uint256 public rU; // USDC, 6 decimals, held on the EVM (the float on Core is `coreU()`)
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    Stage public stage;
    bool public sellingHype;
    uint256 public inFlight; // sell: HYPE taken out of rH; buy: float (6 decimals) to spend
    uint64 public coreBefore; // sell: Core HYPE balance when `start` ran
    uint256 public startedAt;
    uint256 public orderedAt;
    uint256 public expectH; // EVM balances `finish` waits for; fixed by the first `sendBack`
    uint256 public expectU;
    uint64 public floatAfter; // Core USDC the first `sendBack` meant to leave on Core
    uint256 public sentInBlock;

    event Swap(address indexed who, bool hypeIn, uint256 amountIn, uint256 amountOut);
    event Liquidity(address indexed who, int256 shareDelta, uint256 h, uint256 u);
    event Rebalance(Stage stage, uint256 a, uint256 b);

    error NotKeeper();
    error Busy();
    error WrongStage(Stage want);
    error Slippage();
    error WrongDirection();
    error TooMuch(uint256 max);
    error NotYet();
    error TooSmall();
    error NotEnoughEvmUsdc(uint256 have);
    error NotEnoughEvmHype(uint256 have);

    constructor(IERC20 usdc_, address keeper_, uint64 hypeToken_, uint64 spotIndex_, uint8 hypeSzDecimals_) {
        usdc = usdc_;
        keeper = keeper_;
        hypeToken = hypeToken_;
        spotIndex = spotIndex_;
        hypeSzDecimals = hypeSzDecimals_;
    }

    modifier idle() {
        if (stage != Stage.Idle) revert Busy();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    modifier at(Stage s) {
        if (msg.sender != keeper) revert NotKeeper();
        if (stage != s) revert WrongStage(s);
        _;
    }

    // ---------------------------------------------------------------- liquidity

    /// Deposit `msg.value` HYPE and `u` USDC. Anything beyond the pool ratio is donated.
    function add(uint256 u, uint256 minShares) external payable idle returns (uint256 s) {
        uint256 h = msg.value;
        _pullUsdc(u);
        if (totalShares == 0) {
            // A float already on Core (anyone can send to the pool's Core account) would go to
            // whoever mints first; only the keeper may (review r3).
            if (msg.sender != keeper) revert NotKeeper();
            s = _sqrt(h * u) - MIN_LIQUIDITY;
            totalShares = MIN_LIQUIDITY; // locked
        } else {
            s = _min(h * totalShares / reserveH(), u * totalShares / reserveU());
        }
        if (s == 0 || s < minShares) revert Slippage();
        totalShares += s;
        shares[msg.sender] += s;
        rH += h;
        rU += u;
        emit Liquidity(msg.sender, int256(s), h, u);
    }

    function remove(uint256 s, uint256 minH, uint256 minU) external idle returns (uint256 h, uint256 u) {
        h = s * reserveH() / totalShares;
        u = s * reserveU() / totalShares;
        if (h < minH || u < minU) revert Slippage();
        if (h > rH) revert NotEnoughEvmHype(rH);
        if (u > rU) revert NotEnoughEvmUsdc(rU);
        shares[msg.sender] -= s;
        totalShares -= s;
        rH -= h;
        rU -= u;
        _sendHype(msg.sender, h);
        _sendUsdc(msg.sender, u);
        emit Liquidity(msg.sender, -int256(s), h, u);
    }

    // ---------------------------------------------------------------- swaps

    function swapHypeForUsdc(uint256 minOut) external payable idle returns (uint256 out) {
        out = _out(msg.value, reserveH(), reserveU());
        if (out < minOut) revert Slippage();
        if (out > rU) revert NotEnoughEvmUsdc(rU);
        rH += msg.value;
        rU -= out;
        _sendUsdc(msg.sender, out);
        emit Swap(msg.sender, true, msg.value, out);
    }

    function swapUsdcForHype(uint256 u, uint256 minOut) external idle returns (uint256 out) {
        _pullUsdc(u);
        out = _out(u, reserveU(), reserveH());
        if (out < minOut) revert Slippage();
        if (out > rH) revert NotEnoughEvmHype(rH);
        rU += u;
        rH -= out;
        _sendHype(msg.sender, out);
        emit Swap(msg.sender, false, u, out);
    }

    function _out(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inAfterFee = amountIn * (10_000 - FEE_BPS);
        return inAfterFee * rOut / (rIn * 10_000 + inAfterFee);
    }

    // ---------------------------------------------------------------- rebalance

    /// The USDC float on the pool's Core account, 6 decimals (Core has 8; the rest is dust).
    function coreU() public view returns (uint256) {
        return Core.spotBalance(address(this), Core.USDC).total / 100;
    }

    /// HYPE on the pool's Core account above the keeper's ops float, 18 decimals.
    function coreH() public view returns (uint256) {
        uint64 b = Core.spotBalance(address(this), hypeToken).total;
        return b > KEEP_HYPE_WEI ? uint256(b - KEEP_HYPE_WEI) * 1e10 : 0;
    }

    /// All the pool's USDC: EVM plus the Core float. Meaningful while `Idle`.
    function reserveU() public view returns (uint256) {
        return rU + coreU();
    }

    /// All the pool's HYPE: EVM plus Core. Meaningful while `Idle`.
    function reserveH() public view returns (uint256) {
        return rH + coreH();
    }

    /// Pool price, USDC per HYPE with 6 decimals.
    function poolPx() public view returns (uint256) {
        return reserveU() * 1e18 / reserveH();
    }

    /// Core spot price, USDC per HYPE with 6 decimals.
    function corePx() public view returns (uint256) {
        uint256 px = Core.spotPx(spotIndex); // 8 - szDecimals decimals
        uint8 d = 8 - hypeSzDecimals;
        return d >= 6 ? px / 10 ** (d - 6) : px * 10 ** (6 - d);
    }

    /// Most of the over-weight token that can be traded on Core without pushing the pool past the
    /// Core price: HYPE (18 decimals) when the pool is cheap, USDC (6 decimals) when it is dear.
    function maxRebalance() public view returns (bool sellHype, uint256 amount) {
        return _maxRebalance(reserveH(), reserveU(), corePx());
    }

    function _maxRebalance(uint256 h, uint256 u, uint256 p) internal pure returns (bool, uint256) {
        uint256 uAtCore = p * h / 1e18; // USDC the HYPE reserve is worth at the Core price
        if (uAtCore > u) {
            // (u + dh·p) / (h - dh) = p  =>  dh = (p·h - u) / 2p
            return (true, (uAtCore - u) * 1e18 / (2 * p));
        }
        // (u - du) / (h + du/p) = p  =>  du = (u - p·h) / 2
        return (false, (u - uAtCore) / 2);
    }

    /// Keeper-paid HYPE for the pool's Core account (gas for Core -> EVM sends, account
    /// activation). Not part of the reserves.
    function fundOps() external payable onlyKeeper {
        (bool ok,) = Core.HYPE_SYSTEM.call{value: msg.value}("");
        require(ok);
    }

    /// Step 1. Sell: bridge `amount` HYPE to the pool's Core account. Buy: earmark `amount` of
    /// the Core float (6 decimals); nothing moves.
    function start(bool sellHype, uint256 amount) external at(Stage.Idle) {
        uint256 p = corePx();
        (bool dir, uint256 max) = _maxRebalance(reserveH(), reserveU(), p);
        if (dir != sellHype) revert WrongDirection();
        if (amount > max) revert TooMuch(max);
        if ((sellHype ? amount * p / 1e18 : amount) < MIN_NOTIONAL) revert TooSmall();
        sellingHype = sellHype;
        inFlight = amount;
        startedAt = block.timestamp;
        if (sellHype) {
            coreBefore = Core.spotBalance(address(this), hypeToken).total;
            rH -= amount;
            (bool ok,) = Core.HYPE_SYSTEM.call{value: amount}("");
            require(ok);
        } else {
            uint256 f = coreU();
            if (amount > f) revert TooMuch(f);
        }
        stage = Stage.OnCore;
        emit Rebalance(Stage.OnCore, sellHype ? 1 : 0, amount);
    }

    /// Sell leg: HYPE that has arrived on Core since `start`, in Core wei.
    function arrived() public view returns (uint64) {
        uint64 nowBal = Core.spotBalance(address(this), hypeToken).total;
        return nowBal > coreBefore ? nowBal - coreBefore : 0;
    }

    /// Step 2: one IOC on the Core spot market, limit `SLIPPAGE_BPS` off the Core price read now
    /// but never worse than the pool's own price: CoreWriter orders run seconds later, so the
    /// limit is what protects LPs if the price turns in between (review r2). Reverts if the price
    /// has already turned; the keeper then calls `sendBack` to bring the HYPE home untraded.
    function order() external at(Stage.OnCore) {
        uint256 p = corePx(); // 6 decimals
        // HYPE in the pool: EVM, Core, and (sell) the part of the bridge not yet on Core
        uint256 h = reserveH();
        if (sellingHype) {
            uint256 landed = uint256(arrived()) * 1e10;
            if (inFlight > landed) h += inFlight - landed;
        }
        uint256 u = reserveU();
        uint256 pool = u * 1e18 / h; // pool price before this trade, 6 decimals
        (bool dir, uint256 max) = _maxRebalance(h, u, p);
        if (dir != sellingHype || max == 0) revert WrongDirection();

        uint64 lotWei = uint64(10 ** (8 - hypeSzDecimals)); // size step, in 1e8 units
        uint64 sz;
        uint256 limit;
        if (sellingHype) {
            uint64 got = arrived();
            uint256 cap = max / 1e10; // 18 -> 8 decimals
            sz = uint64(got < cap ? got : cap) / lotWei * lotWei;
            limit = p * (10_000 - SLIPPAGE_BPS) / 10_000;
            if (limit < pool) limit = pool; // never sell below the pool price
        } else {
            uint256 spend = _min(_min(inFlight, max), coreU()) * 100; // USDC, 8 decimals
            limit = p * (10_000 + SLIPPAGE_BPS) / 10_000;
            if (limit > pool) limit = pool; // never buy above the pool price
            // HYPE (1e8 units) = USDC (1e8) / price (1e6) * 1e6
            sz = uint64(spend * 1e6 / limit) / lotWei * lotWei;
        }
        if (sz == 0 || uint256(sz) * p / 1e8 < MIN_NOTIONAL) revert NotYet();
        uint64 px = _toTick(limit * 100, sellingHype); // 6 -> 8 decimals; round away from a loss
        Core.limitOrder(uint32(10_000 + spotIndex), !sellingHype, px, sz, false, Core.TIF_IOC, 0);
        orderedAt = block.timestamp;
        stage = Stage.Ordered;
        emit Rebalance(Stage.Ordered, px, sz);
    }

    /// Step 3: send HYPE above the ops float, and `uToEvm` (Core wei) of the USDC float, to the
    /// EVM. The rest of the USDC stays on Core as float.
    /// - From `Ordered`, after `ORDER_DELAY` (the IOC has settled).
    /// - From `OnCore` without trading: a buy at any time; a sell once the HYPE has arrived, or
    ///   after `STUCK_DELAY` (a bridge that never arrives is then a recognised loss).
    /// - From `Idle`, to move float to the EVM.
    /// - From `Returning` again, in a later block, to resend what a dropped send left on Core.
    /// The first call fixes `expectH`/`expectU`; later calls never change them, so a send whose
    /// Core debit has happened but whose EVM credit is pending stays owed.
    function sendBack(uint64 uToEvm) external onlyKeeper {
        if (stage == Stage.Ordered) {
            if (block.timestamp < orderedAt + ORDER_DELAY) revert NotYet();
        } else if (stage == Stage.OnCore) {
            if (sellingHype && arrived() == 0 && block.timestamp < startedAt + STUCK_DELAY) revert NotYet();
        } else if (stage == Stage.Returning) {
            if (block.number <= sentInBlock) revert NotYet(); // let Core process the first send
        }
        uint64 h = Core.spotBalance(address(this), hypeToken).total;
        uint64 u = Core.spotBalance(address(this), Core.USDC).total;
        uint64 hSend = h > KEEP_HYPE_WEI ? h - KEEP_HYPE_WEI : 0;
        uint64 uSend;
        if (stage == Stage.Returning) {
            uSend = u > floatAfter ? (u - floatAfter) / 100 * 100 : 0; // only what a dropped send left
        } else {
            uSend = (uToEvm < u ? uToEvm : u) / 100 * 100; // EVM USDC has 6 decimals, Core 8
            floatAfter = u - uSend;
            expectH = rH + uint256(hSend) * 1e10;
            expectU = rU + uSend / 100;
            stage = Stage.Returning;
        }
        if (hSend > 0) {
            Core.sendAsset(Core.HYPE_SYSTEM, Core.SPOT_DEX, Core.SPOT_DEX, hypeToken, hSend);
        }
        if (uSend > 0) {
            Core.sendAsset(Core.systemAddress(Core.USDC, hypeToken), Core.SPOT_DEX, Core.SPOT_DEX, Core.USDC, uSend);
        }
        sentInBlock = block.number;
        emit Rebalance(Stage.Returning, hSend, uSend);
    }

    /// Step 4: Core -> EVM credits do not call the contract, so check the balances.
    function finish() external at(Stage.Returning) {
        uint256 h = address(this).balance;
        uint256 u = usdc.balanceOf(address(this));
        if (h < expectH || u < expectU) revert NotYet();
        rH = h;
        rU = u;
        inFlight = 0;
        stage = Stage.Idle;
        emit Rebalance(Stage.Idle, h, u);
    }

    /// Round to 5 significant figures and at most `8 - szDecimals` decimals (Core spot tick
    /// rules), up for a sell limit and down for a buy limit. `px8` has 8 decimals.
    function _toTick(uint256 px8, bool up) internal view returns (uint64) {
        uint256 step = 10 ** hypeSzDecimals; // max decimals 8 - szDecimals
        uint256 digits;
        for (uint256 x = px8; x > 0; x /= 10) digits++;
        // significant figures counted on the human value, which has 8 decimals here
        if (digits > 5) {
            uint256 sig = 10 ** (digits - 5);
            if (sig > step) step = sig;
        }
        uint256 down = px8 / step * step;
        return uint64(up && down < px8 ? down + step : down);
    }

    // ---------------------------------------------------------------- helpers

    function _pullUsdc(uint256 u) internal {
        if (u > 0) require(_call(address(usdc), abi.encodeCall(IERC20Transfer.transferFrom, (msg.sender, address(this), u))));
    }

    function _sendUsdc(address to, uint256 u) internal {
        if (u > 0) require(_call(address(usdc), abi.encodeCall(IERC20.transfer, (to, u))));
    }

    function _sendHype(address to, uint256 h) internal {
        if (h > 0) {
            (bool ok,) = to.call{value: h}("");
            require(ok);
        }
    }

    function _call(address t, bytes memory data) internal returns (bool) {
        (bool ok, bytes memory ret) = t.call(data);
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }


    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    receive() external payable {}
}

interface IERC20Transfer {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
