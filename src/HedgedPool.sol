// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Core, IERC20} from "./Core.sol";

/// @notice HYPE/USDC x·y=k pool that closes its own gap to the HyperCore spot price by trading
/// on HyperCore, instead of leaving it to outside arbitrageurs. See docs/design.md.
///
/// No books. The pool's reserves are its actual balances, read every time: native HYPE and USDC
/// on the EVM, plus HYPE and USDC on the pool's own Core account (spot-balance precompile). A
/// CoreWriter order that fills late, a transfer that lands late, a transfer Core rejects: each
/// only changes balances that are already counted, so there is nothing to reconcile (review
/// rounds 1-5 all came from keeping books the EVM cannot check, docs/reviews/r5.md).
///
/// Two things balances cannot show, and the pool pauses swaps and liquidity for both:
/// - A transfer between the EVM and Core while it moves. By Hyperliquid's documented ordering,
///   EVM -> Core transfers are processed right after the EVM block that sent them and Core -> EVM
///   transfers are credited in the next HyperEVM block: `QUIET_BLOCKS` after any transfer.
/// - A Core order that has been sent but not yet run (CoreWriter delays orders "a few seconds").
///   Trading the AMM meanwhile would let someone move the pool price around the order and keep
///   the difference (review r6). `ORDER_QUIET` after any order. This one is a time assumption,
///   with no documented bound; if an order ever ran later, the loss is bounded by that order.
///
/// USDC only moves Core -> EVM (EVM -> Core into a contract's Core account did not credit on
/// testnet, docs/step1-bridging.md): HYPE is bought on Core with the USDC float, and sales add
/// to it. Payouts come only from the EVM side; anyone can move Core inventory to the EVM, except
/// the USDC float floor the keeper keeps for buys.
contract HedgedPool {
    uint256 public constant FEE_BPS = 30;
    uint256 public constant MAX_SPREAD_BPS = 500; // no orders into a Core book wider than this
    /// Core spot taker fee assumed when judging a trade, a little above the 7 bp base rate, so
    /// the pool only trades when the price it actually gets beats its own (review r7).
    uint256 public constant TAKER_FEE_BPS = 10;
    uint256 public constant MIN_NOTIONAL = 11e6; // USDC; Core spot rejects orders under 10 USDC
    uint256 public constant QUIET_BLOCKS = 2; // one block for the documented ordering, one spare
    uint256 public constant ORDER_QUIET = 30; // seconds; ~10x the measured fill delay (<= 4 s)
    uint256 public constant MAX_FLOOR_BPS = 1_000; // the protected USDC float is at most 10% of all USDC
    /// HYPE kept on the pool's Core account to pay for Core -> EVM sends. Funded by the keeper
    /// through `fundOps`; not part of the reserves.
    uint64 public constant KEEP_HYPE_WEI = 1e6; // 0.01 HYPE
    uint256 internal constant MIN_LIQUIDITY = 1000;

    IERC20 public immutable usdc;
    address public immutable keeper;
    uint64 public immutable hypeToken; // Core token index (testnet 1105, mainnet 150)
    uint64 public immutable spotIndex; // HYPE/USDC spot pair (testnet 1035, mainnet 107)
    uint8 public immutable hypeSzDecimals; // 2

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    uint256 public quietUntil; // swaps and liquidity wait while block.number <= quietUntil
    uint256 public quietUntilTime; // ... and while block.timestamp < quietUntilTime (after an order)
    uint64 public floatFloor; // Core USDC (8 decimals) only the keeper may move to the EVM

    event Swap(address indexed who, bool hypeIn, uint256 amountIn, uint256 amountOut);
    event Liquidity(address indexed who, int256 shareDelta, uint256 h, uint256 u);
    event Bridged(uint256 hype);
    event Ordered(bool sellHype, uint64 px, uint64 sz);
    event ToEvm(address indexed by, uint64 hypeWei, uint64 usdcWei);

    error NotKeeper();
    error Busy();
    error Slippage();
    error WrongDirection();
    error TooMuch(uint256 max);
    error TooSmall();
    error NotEnoughEvmUsdc(uint256 have);
    error NotEnoughEvmHype(uint256 have);
    error NoCoreAccount();
    error WideBook(uint256 spreadBps);
    error BadQuote(uint256 bid, uint256 ask);

    constructor(IERC20 usdc_, address keeper_, uint64 hypeToken_, uint64 spotIndex_, uint8 hypeSzDecimals_) {
        usdc = usdc_;
        keeper = keeper_;
        hypeToken = hypeToken_;
        spotIndex = spotIndex_;
        hypeSzDecimals = hypeSzDecimals_;
    }

    modifier settled() {
        if (block.number <= quietUntil || block.timestamp < quietUntilTime) revert Busy();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    // ---------------------------------------------------------------- reserves

    /// HYPE on the pool's Core account above the keeper's ops float, 18 decimals.
    function coreH() public view returns (uint256) {
        uint64 b = Core.spotBalance(address(this), hypeToken).total;
        return b > KEEP_HYPE_WEI ? uint256(b - KEEP_HYPE_WEI) * 1e10 : 0;
    }

    /// USDC on the pool's Core account, 6 decimals (Core has 8; the rest is dust).
    function coreU() public view returns (uint256) {
        return Core.spotBalance(address(this), Core.USDC).total / 100;
    }

    function reserveH() public view returns (uint256) {
        return address(this).balance + coreH();
    }

    function reserveU() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + coreU();
    }

    /// Pool price, USDC per HYPE with 6 decimals.
    function poolPx() public view returns (uint256) {
        return reserveU() * 1e18 / reserveH();
    }

    // ---------------------------------------------------------------- liquidity

    /// Deposit `msg.value` HYPE and `u` USDC. Anything beyond the pool ratio is donated.
    function add(uint256 u, uint256 minShares) external payable settled returns (uint256 s) {
        uint256 h = msg.value;
        uint256 hBefore = reserveH() - h;
        uint256 uBefore = reserveU();
        _pullUsdc(u);
        if (totalShares == 0) {
            // Anything already in the pool (anyone can send to it, on the EVM or on Core) would go
            // to whoever mints first; only the keeper may (review r3).
            if (msg.sender != keeper) revert NotKeeper();
            s = _sqrt(h * u) - MIN_LIQUIDITY;
            totalShares = MIN_LIQUIDITY; // locked
        } else {
            s = _min(h * totalShares / hBefore, u * totalShares / uBefore);
        }
        if (s == 0 || s < minShares) revert Slippage();
        totalShares += s;
        shares[msg.sender] += s;
        emit Liquidity(msg.sender, int256(s), h, u);
    }

    function remove(uint256 s, uint256 minH, uint256 minU) external settled returns (uint256 h, uint256 u) {
        h = s * reserveH() / totalShares;
        u = s * reserveU() / totalShares;
        if (h < minH || u < minU) revert Slippage();
        if (h > address(this).balance) revert NotEnoughEvmHype(address(this).balance);
        uint256 eu = usdc.balanceOf(address(this));
        if (u > eu) revert NotEnoughEvmUsdc(eu);
        shares[msg.sender] -= s;
        totalShares -= s;
        _sendHype(msg.sender, h);
        _sendUsdc(msg.sender, u);
        emit Liquidity(msg.sender, -int256(s), h, u);
    }

    // ---------------------------------------------------------------- swaps

    function swapHypeForUsdc(uint256 minOut) external payable settled returns (uint256 out) {
        out = _out(msg.value, reserveH() - msg.value, reserveU());
        if (out < minOut) revert Slippage();
        uint256 eu = usdc.balanceOf(address(this));
        if (out > eu) revert NotEnoughEvmUsdc(eu);
        _sendUsdc(msg.sender, out);
        emit Swap(msg.sender, true, msg.value, out);
    }

    function swapUsdcForHype(uint256 u, uint256 minOut) external settled returns (uint256 out) {
        out = _out(u, reserveU(), reserveH());
        if (out < minOut) revert Slippage();
        if (out > address(this).balance) revert NotEnoughEvmHype(address(this).balance);
        _pullUsdc(u);
        _sendHype(msg.sender, out);
        emit Swap(msg.sender, false, u, out);
    }

    function _out(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inAfterFee = amountIn * (10_000 - FEE_BPS);
        return inAfterFee * rOut / (rIn * 10_000 + inAfterFee);
    }

    // ---------------------------------------------------------------- rebalance (keeper)

    /// Core best bid and ask, USDC per HYPE with 6 decimals, checked: both sides present, not
    /// crossed, no wider than `MAX_SPREAD_BPS` (review r7). The last trade price (0x808) is not
    /// used: on a wide book it sits at one side, and a limit set off it may never fill (testnet).
    function coreBbo() public view returns (uint256 bid, uint256 ask) {
        (uint64 b, uint64 a) = Core.bbo(uint32(10_000 + spotIndex)); // 8 - szDecimals decimals
        (bid, ask) = (_to6(b), _to6(a));
        if (bid == 0 || ask < bid) revert BadQuote(bid, ask);
        uint256 spread = ((ask - bid) * 20_000 + (bid + ask) - 1) / (bid + ask); // bps of mid, rounded up
        if (spread > MAX_SPREAD_BPS) revert WideBook(spread);
    }

    /// Core mid price, USDC per HYPE with 6 decimals.
    function corePx() public view returns (uint256) {
        (uint256 bid, uint256 ask) = coreBbo();
        return (bid + ask) / 2;
    }

    /// The prices the pool would actually get on Core, after the taker fee: selling at the bid,
    /// buying at the ask.
    function executable() public view returns (uint256 sellNet, uint256 buyGross, uint256 bid, uint256 ask) {
        (bid, ask) = coreBbo();
        sellNet = bid * (10_000 - TAKER_FEE_BPS) / 10_000;
        buyGross = (ask * (10_000 + TAKER_FEE_BPS) + 9_999) / 10_000;
    }

    function _to6(uint256 px) internal view returns (uint256) {
        uint8 d = 8 - hypeSzDecimals;
        return d >= 6 ? px / 10 ** (d - 6) : px * 10 ** (6 - d);
    }

    /// Most of the over-weight token that can be traded on Core without pushing the pool past the
    /// price it would actually get there: HYPE (18 decimals) to sell when the bid after fees is
    /// above the pool price, USDC (6 decimals) to spend when the ask after fees is below it, and
    /// nothing in between (review r7: sizing on the mid lost the spread and fees to LPs).
    function maxRebalance() public view returns (bool sellHype, uint256 amount) {
        (uint256 sellNet, uint256 buyGross,,) = executable();
        return _maxExecutable(reserveH(), reserveU(), sellNet, buyGross);
    }

    function _maxExecutable(uint256 h, uint256 u, uint256 sellNet, uint256 buyGross)
        internal
        pure
        returns (bool, uint256)
    {
        uint256 pool = u * 1e18 / h;
        if (sellNet > pool) return _maxRebalance(h, u, sellNet);
        if (buyGross < pool) return _maxRebalance(h, u, buyGross);
        return (false, 0);
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

    /// Keeper-paid HYPE for the pool's Core account: account activation and gas for Core -> EVM
    /// sends. Not part of the reserves.
    function fundOps() external payable onlyKeeper {
        _quiet();
        (bool ok,) = Core.HYPE_SYSTEM.call{value: msg.value}("");
        require(ok);
    }

    function setFloatFloor(uint64 wei8) external onlyKeeper {
        floatFloor = wei8;
    }

    /// The protected float in effect: the keeper's `floatFloor`, capped at `MAX_FLOOR_BPS` of all
    /// the pool's USDC so payouts never depend on the keeper alone (review r6). Core 8 decimals.
    function effectiveFloor() public view returns (uint64) {
        uint256 cap = reserveU() * MAX_FLOOR_BPS / 10_000 * 100;
        return floatFloor < cap ? floatFloor : uint64(cap);
    }

    /// Move `amount` HYPE (18 decimals) to the pool's Core account, to sell there. Only when the
    /// pool is cheap, and no more than `maxRebalance`.
    function bridgeHype(uint256 amount) external onlyKeeper settled {
        (bool sell, uint256 max) = maxRebalance();
        if (!sell || max == 0) revert WrongDirection();
        if (amount > max) revert TooMuch(max);
        (uint256 bid,) = coreBbo();
        if (amount * bid / 1e18 < MIN_NOTIONAL) revert TooSmall();
        // the Core account must already exist (the keeper's `fundOps` creates it), so activation
        // is not paid out of LP HYPE (review r4). Not a balance threshold: gas for anyone's
        // `toEvm` would wear it down and block bridging (review r6).
        if (!Core.userExists(address(this))) revert NoCoreAccount();
        _quiet();
        (bool ok,) = Core.HYPE_SYSTEM.call{value: amount}("");
        require(ok);
        emit Bridged(amount);
    }

    /// One IOC on the Core spot market, spending at most `amount` of what is on Core (HYPE, 18
    /// decimals, to sell; USDC, 6 decimals, to buy) and no more than `maxRebalance`. Only when the
    /// price after fees beats the pool price; the limit is the best bid (sell) or ask (buy), so a
    /// fill seconds later is at that price or better (review r2, r7). If Core rejects it, or it
    /// fills late, only counted balances change.
    function order(bool sellHype, uint256 amount) external onlyKeeper settled {
        (uint256 sellNet, uint256 buyGross, uint256 bid, uint256 ask) = executable(); // 6 decimals
        uint256 p = (bid + ask) / 2;
        (bool dir, uint256 max) = _maxExecutable(reserveH(), reserveU(), sellNet, buyGross);
        if (dir != sellHype || max == 0) revert WrongDirection();

        uint64 lotWei = uint64(10 ** (8 - hypeSzDecimals)); // size step, in 1e8 units
        uint64 sz;
        uint256 limit;
        if (sellHype) {
            uint256 h = _min(_min(amount, max), coreH()) / 1e10; // 18 -> 8 decimals
            sz = uint64(h) / lotWei * lotWei;
            limit = bid; // its net is above the pool price, or there is no max
        } else {
            uint256 spend = _min(_min(amount, max), coreU()) * 100; // USDC, 8 decimals
            limit = ask; // its gross is below the pool price, or there is no max
            // HYPE (1e8 units) = USDC (1e8) / price (1e6) * 1e6
            sz = uint64(spend * 1e6 / limit) / lotWei * lotWei;
        }
        if (sz == 0 || uint256(sz) * p / 1e8 < MIN_NOTIONAL) revert TooSmall();
        uint64 px = _toTick(limit * 100, sellHype); // 6 -> 8 decimals; a bid/ask is already a tick
        quietUntilTime = block.timestamp + ORDER_QUIET; // also blocks `toEvm` taking the order's input
        Core.limitOrder(uint32(10_000 + spotIndex), !sellHype, px, sz, false, Core.TIF_IOC, 0);
        emit Ordered(sellHype, px, sz);
    }

    // ---------------------------------------------------------------- Core -> EVM (anyone)

    /// Bring Core inventory to the EVM: up to `hypeWei` of HYPE above the ops float and up to
    /// `usdcWei` of USDC (Core 8 decimals). Anyone may call it, so payouts can always be unblocked;
    /// only the keeper may take USDC below `effectiveFloor()`, the float buys need (review r5). A send
    /// Core rejects (e.g. a pending order spent the balance first) leaves the tokens on Core,
    /// still counted. Others must move at least `MIN_NOTIONAL`, which prices out pausing the
    /// pool for free.
    function toEvm(uint64 hypeWei, uint64 usdcWei) external settled {
        uint64 h = Core.spotBalance(address(this), hypeToken).total;
        uint64 u = Core.spotBalance(address(this), Core.USDC).total;
        uint64 hFree = h > KEEP_HYPE_WEI ? h - KEEP_HYPE_WEI : 0;
        uint64 floor = effectiveFloor();
        uint64 uFree = msg.sender == keeper ? u : (u > floor ? u - floor : 0);
        uint64 hSend = hypeWei < hFree ? hypeWei : hFree;
        uint64 uSend = (usdcWei < uFree ? usdcWei : uFree) / 100 * 100; // EVM USDC has 6 decimals
        if (hSend == 0 && uSend == 0) revert TooSmall();
        if (msg.sender != keeper) {
            // HYPE valued at the checked bid: a one-sided or crossed book reverts (review r7)
            (uint256 bid,) = hSend > 0 ? coreBbo() : (0, 0);
            if (uint256(hSend) * bid / 1e8 + uSend / 100 < MIN_NOTIONAL) revert TooSmall();
        }
        _quiet();
        if (hSend > 0) {
            Core.sendAsset(Core.HYPE_SYSTEM, Core.SPOT_DEX, Core.SPOT_DEX, hypeToken, hSend);
        }
        if (uSend > 0) {
            Core.sendAsset(Core.systemAddress(Core.USDC, hypeToken), Core.SPOT_DEX, Core.SPOT_DEX, Core.USDC, uSend);
        }
        emit ToEvm(msg.sender, hSend, uSend);
    }

    // ---------------------------------------------------------------- helpers

    function _quiet() internal {
        quietUntil = block.number + QUIET_BLOCKS;
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
