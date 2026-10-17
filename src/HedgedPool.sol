// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Core, ICoreDepositWallet, IERC20} from "./Core.sol";

/// @notice HYPE/USDC x·y=k pool that closes its own gap to the HyperCore spot price by trading
/// on HyperCore, instead of leaving it to outside arbitrageurs. See docs/design.md.
/// v1: the keeper is one address, and the pool is paused while a rebalance is in flight.
contract HedgedPool {
    enum Stage {
        Idle,
        OnCore, // tokens bridged to the pool's Core account
        Ordered, // IOC sent on the Core spot market
        Returning // Core balances sent back to the EVM
    }

    uint256 public constant FEE_BPS = 30;
    uint256 public constant SLIPPAGE_BPS = 100; // IOC limit vs Core spot price
    uint256 public constant ORDER_DELAY = 10; // seconds before `sendBack` may read the fill
    uint64 public constant KEEP_HYPE_WEI = 1e6; // 0.01 HYPE left on Core to pay Core -> EVM sends
    uint256 internal constant MIN_LIQUIDITY = 1000;

    IERC20 public immutable usdc;
    address public immutable depositWallet;
    address public immutable keeper;
    uint64 public immutable hypeToken; // Core token index (testnet 1105, mainnet 150)
    uint64 public immutable spotIndex; // HYPE/USDC spot pair (testnet 1035, mainnet 107)
    uint8 public immutable hypeSzDecimals; // 2

    uint256 public rH; // HYPE, 18 decimals, held on the EVM
    uint256 public rU; // USDC, 6 decimals, held on the EVM
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    Stage public stage;
    bool public sellingHype;
    uint256 public orderedAt;
    uint256 public expectH; // EVM balances `finish` waits for
    uint256 public expectU;

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

    constructor(
        IERC20 usdc_,
        address depositWallet_,
        address keeper_,
        uint64 hypeToken_,
        uint64 spotIndex_,
        uint8 hypeSzDecimals_
    ) {
        usdc = usdc_;
        depositWallet = depositWallet_;
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
            s = _sqrt(h * u) - MIN_LIQUIDITY;
            totalShares = MIN_LIQUIDITY; // locked
        } else {
            s = _min(h * totalShares / rH, u * totalShares / rU);
        }
        if (s == 0 || s < minShares) revert Slippage();
        totalShares += s;
        shares[msg.sender] += s;
        rH += h;
        rU += u;
        emit Liquidity(msg.sender, int256(s), h, u);
    }

    function remove(uint256 s, uint256 minH, uint256 minU) external idle returns (uint256 h, uint256 u) {
        h = s * rH / totalShares;
        u = s * rU / totalShares;
        if (h < minH || u < minU) revert Slippage();
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
        out = _out(msg.value, rH, rU);
        if (out < minOut) revert Slippage();
        rH += msg.value;
        rU -= out;
        _sendUsdc(msg.sender, out);
        emit Swap(msg.sender, true, msg.value, out);
    }

    function swapUsdcForHype(uint256 u, uint256 minOut) external idle returns (uint256 out) {
        _pullUsdc(u);
        out = _out(u, rU, rH);
        if (out < minOut) revert Slippage();
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

    /// Pool price, USDC per HYPE with 6 decimals.
    function poolPx() public view returns (uint256) {
        return rU * 1e18 / rH;
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
        uint256 p = corePx();
        uint256 pool = poolPx();
        uint256 rUAtCore = p * rH / 1e18; // USDC the HYPE reserve is worth at the Core price
        if (pool < p && rUAtCore > rU) {
            // (rU + dh·p) / (rH - dh) = p  =>  dh = (p·rH - rU) / 2p
            return (true, (rUAtCore - rU) * 1e18 / (2 * p));
        }
        if (pool > p && rU > rUAtCore) {
            // (rU - du) / (rH + du/p) = p  =>  du = (rU - p·rH) / 2
            return (false, (rU - rUAtCore) / 2);
        }
    }

    /// Step 1: bridge `amount` of the over-weight token to the pool's Core account.
    function start(bool sellHype, uint256 amount) external at(Stage.Idle) {
        (bool dir, uint256 max) = maxRebalance();
        if (dir != sellHype) revert WrongDirection();
        if (amount > max) revert TooMuch(max);
        sellingHype = sellHype;
        if (sellHype) {
            rH -= amount;
            (bool ok,) = Core.HYPE_SYSTEM.call{value: amount}("");
            require(ok);
        } else {
            rU -= amount;
            usdc.approve(depositWallet, amount);
            ICoreDepositWallet(depositWallet).deposit(amount, Core.SPOT_DEX);
        }
        stage = Stage.OnCore;
        emit Rebalance(Stage.OnCore, sellHype ? 1 : 0, amount);
    }

    /// Step 2: one IOC on the Core spot market for what arrived, limit `SLIPPAGE_BPS` off the
    /// Core price read now.
    function order() external at(Stage.OnCore) {
        uint256 p = corePx(); // 6 decimals
        uint64 lotWei = uint64(10 ** (8 - hypeSzDecimals)); // size step, in 1e8 units
        uint64 sz;
        uint256 limit;
        if (sellingHype) {
            uint64 have = Core.spotBalance(address(this), hypeToken).total;
            if (have <= KEEP_HYPE_WEI) revert NotYet();
            sz = (have - KEEP_HYPE_WEI) / lotWei * lotWei;
            limit = p * (10_000 - SLIPPAGE_BPS) / 10_000;
        } else {
            uint64 have = Core.spotBalance(address(this), Core.USDC).total; // 8 decimals
            if (have == 0) revert NotYet();
            limit = p * (10_000 + SLIPPAGE_BPS) / 10_000;
            // HYPE (1e8 units) = USDC (1e8) / price (1e6) * 1e6
            sz = uint64(uint256(have) * 1e6 / limit) / lotWei * lotWei;
        }
        uint64 px = _toTick(limit * 100); // 6 -> 8 decimals, valid Core price
        Core.limitOrder(uint32(10_000 + spotIndex), !sellingHype, px, sz, false, Core.TIF_IOC, 0);
        orderedAt = block.timestamp;
        stage = Stage.Ordered;
        emit Rebalance(Stage.Ordered, px, sz);
    }

    /// Step 3: send everything on Core back to the EVM (keeping a little HYPE for gas). Callable
    /// again from `Returning` in case a send was dropped.
    function sendBack() external onlyKeeper {
        if (stage == Stage.Ordered) {
            if (block.timestamp < orderedAt + ORDER_DELAY) revert NotYet();
        } else if (stage != Stage.Returning) {
            revert WrongStage(Stage.Ordered);
        }
        uint64 h = Core.spotBalance(address(this), hypeToken).total;
        uint64 u = Core.spotBalance(address(this), Core.USDC).total;
        uint64 hSend = h > KEEP_HYPE_WEI ? h - KEEP_HYPE_WEI : 0;
        uint64 uSend = u / 100 * 100; // EVM USDC has 6 decimals, Core 8
        if (hSend > 0) {
            Core.sendAsset(Core.HYPE_SYSTEM, Core.SPOT_DEX, Core.SPOT_DEX, hypeToken, hSend);
        }
        if (uSend > 0) {
            Core.sendAsset(Core.systemAddress(Core.USDC, hypeToken), Core.SPOT_DEX, Core.SPOT_DEX, Core.USDC, uSend);
        }
        expectH = rH + uint256(hSend) * 1e10;
        expectU = rU + uSend / 100;
        stage = Stage.Returning;
        emit Rebalance(Stage.Returning, hSend, uSend);
    }

    /// Step 4: Core -> EVM credits do not call the contract, so check the balances.
    function finish() external at(Stage.Returning) {
        uint256 h = address(this).balance;
        uint256 u = usdc.balanceOf(address(this));
        if (h < expectH || u < expectU) revert NotYet();
        rH = h;
        rU = u;
        stage = Stage.Idle;
        emit Rebalance(Stage.Idle, h, u);
    }

    /// Round down to 5 significant figures and at most `8 - szDecimals` decimals (Core spot
    /// tick rules). `px8` has 8 decimals.
    function _toTick(uint256 px8) internal view returns (uint64) {
        uint256 step = 10 ** hypeSzDecimals; // max decimals 8 - szDecimals
        uint256 digits;
        for (uint256 x = px8; x > 0; x /= 10) digits++;
        // significant figures counted on the human value, which has 8 decimals here
        if (digits > 5) {
            uint256 sig = 10 ** (digits - 5);
            if (sig > step) step = sig;
        }
        return uint64(px8 / step * step);
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
