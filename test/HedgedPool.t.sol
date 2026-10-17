// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Core, IERC20} from "../src/Core.sol";
import {HedgedPool} from "../src/HedgedPool.sol";
import {RecordingWriter} from "./CoreProbe.t.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract HedgedPoolTest is Test {
    uint64 constant HYPE = 1105;
    uint64 constant SPOT = 1035;
    address constant USDC_SYS = 0x2000000000000000000000000000000000000000;

    HedgedPool pool;
    MockUSDC usdc;
    RecordingWriter writer;
    address keeper = address(0xCEE9);
    address lp = address(0x11F);
    address trader = address(0x7AD);

    function setUp() public {
        vm.etch(address(Core.WRITER), address(new RecordingWriter()).code);
        writer = RecordingWriter(address(Core.WRITER));
        usdc = new MockUSDC();
        pool = new HedgedPool(IERC20(address(usdc)), keeper, HYPE, SPOT, 2);

        // the pool's Core account holds only the keeper-funded ops float
        _setCoreBal(HYPE, 1e6);
        _setCoreBal(Core.USDC, 0);
        _setCorePx(40_000_000);
        _setCoreUser(true);

        // 100 HYPE + 4,000 USDC: pool price 40.00. The keeper seeds the first 1%.
        vm.deal(keeper, 1 ether);
        usdc.mint(keeper, 40e6);
        vm.startPrank(keeper);
        usdc.approve(address(pool), type(uint256).max);
        pool.add{value: 1 ether}(40e6, 0);
        vm.stopPrank();
        vm.deal(lp, 1000 ether);
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(pool), type(uint256).max);
        pool.add{value: 99 ether}(3_960e6, 0);
        vm.stopPrank();

        vm.deal(trader, 1000 ether);
        usdc.mint(trader, 1_000_000e6);
        vm.prank(trader);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// A Core book with no spread at `px6`.
    function _setCorePx(uint64 px6) internal {
        _setBbo(px6, px6);
    }

    function _setBbo(uint64 bid6, uint64 ask6) internal {
        // szDecimals 2 -> Core spot prices have 6 decimals; BBO takes the asset id 10000 + spot
        vm.mockCall(Core.BBO, abi.encode(uint32(11035)), abi.encode(bid6, ask6));
    }

    function _setCoreBal(uint64 token, uint64 wei8) internal {
        vm.mockCall(
            Core.SPOT_BALANCE, abi.encode(address(pool), token), abi.encode(Core.SpotBalance(wei8, 0, 0))
        );
    }

    function _setCoreUser(bool exists) internal {
        vm.mockCall(Core.CORE_USER_EXISTS, abi.encode(address(pool)), abi.encode(exists));
    }

    function _order(bool isBuy, uint64 px8, uint64 sz) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"01000001", abi.encode(uint32(11035), isBuy, px8, sz, false, uint8(3), uint128(0))
        );
    }

    function _send(address to, uint64 token, uint64 wei8) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"0100000d", abi.encode(to, address(0), type(uint32).max, type(uint32).max, token, wei8)
        );
    }

    function _pastQuiet() internal {
        vm.roll(pool.quietUntil() + 1);
    }

    // ------------------------------------------------------------ swaps and liquidity

    function test_swapKeepsK() public {
        uint256 k0 = pool.reserveH() * pool.reserveU();
        vm.prank(trader);
        uint256 out = pool.swapHypeForUsdc{value: 1 ether}(0);
        // 1 HYPE into 100/4000 at 30 bp: a bit under 39.6
        assertApproxEqAbs(out, 39_484_000, 50_000);
        assertGe(pool.reserveH() * pool.reserveU(), k0);
    }

    function test_removeAll() public {
        uint256 s = pool.shares(lp);
        vm.prank(lp);
        (uint256 h, uint256 u) = pool.remove(s, 0, 0);
        assertGt(h, 98.99 ether);
        assertGt(u, 3_959e6);
    }

    /// r3: the first mint is the keeper's, so nothing already in the pool can be captured.
    function test_firstMintIsKeepers() public {
        HedgedPool fresh = new HedgedPool(IERC20(address(usdc)), keeper, HYPE, SPOT, 2);
        vm.mockCall(
            Core.SPOT_BALANCE, abi.encode(address(fresh), Core.USDC), abi.encode(Core.SpotBalance(500e8, 0, 0))
        );
        vm.mockCall(
            Core.SPOT_BALANCE, abi.encode(address(fresh), HYPE), abi.encode(Core.SpotBalance(0, 0, 0))
        );
        vm.startPrank(trader);
        usdc.approve(address(fresh), type(uint256).max);
        vm.expectRevert(HedgedPool.NotKeeper.selector);
        fresh.add{value: 0.01 ether}(11e6, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ reserves are balances

    /// The Core float counts in prices and shares, but USDC is paid out only from the EVM, and
    /// anyone can bring float over (above the keeper's floor).
    function test_coreUsdcCountsAndAnyoneBringsIt() public {
        _setCoreBal(Core.USDC, 200e8);
        assertEq(pool.reserveU(), 4_200e6);
        assertEq(pool.poolPx(), 42_000_000);

        uint256 s = pool.shares(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.NotEnoughEvmUsdc.selector, 4_000e6));
        pool.remove(s, 0, 0);

        vm.prank(trader);
        pool.toEvm(0, 200e8);
        assertEq(writer.sent(0), _send(USDC_SYS, 0, 200e8));

        // quiet while the transfer moves
        vm.prank(lp);
        vm.expectRevert(HedgedPool.Busy.selector);
        pool.remove(s, 0, 0);

        _setCoreBal(Core.USDC, 0);
        usdc.mint(address(pool), 200e6); // credited in the next block
        _pastQuiet();
        vm.prank(lp);
        (, uint256 u) = pool.remove(s, 0, 0);
        assertGt(u, 4_157e6); // 99% of 4,200
    }

    /// r4: HYPE donated to the pool's Core account cannot freeze withdrawals.
    function test_coreHypeDonationAnyoneUnfreezes() public {
        _setCoreBal(HYPE, 1e6 + 100e8);
        assertEq(pool.reserveH(), 200 ether);
        uint256 s = pool.shares(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.NotEnoughEvmHype.selector, 100 ether));
        pool.remove(s, 0, 0);

        vm.prank(trader);
        pool.toEvm(100e8, 0);
        assertEq(writer.sent(0), _send(Core.HYPE_SYSTEM, HYPE, 100e8));
        _setCoreBal(HYPE, 1e6);
        vm.deal(address(pool), 200 ether);
        _pastQuiet();
        vm.prank(lp);
        (uint256 h,) = pool.remove(s, 0, 0);
        assertGt(h, 197 ether);
    }

    /// r1/r4/r5: a send Core rejects leaves the tokens on Core, still counted; nothing to settle.
    function test_rejectedSendLosesNothing() public {
        _setCoreBal(Core.USDC, 80e8);
        uint256 before = pool.reserveU();
        vm.prank(keeper);
        pool.toEvm(0, 80e8);
        _pastQuiet(); // Core still shows 80: the send never happened
        assertEq(pool.reserveU(), before);
    }

    /// r5: a credit later than expected is counted the moment it lands; nothing is written off.
    function test_lateCreditCountedWhenItLands() public {
        _setCoreBal(Core.USDC, 80e8);
        vm.prank(keeper);
        pool.toEvm(0, 80e8);
        _setCoreBal(Core.USDC, 0); // debited on Core
        _pastQuiet();
        assertEq(pool.reserveU(), 4_000e6, "in transit: not visible");
        usdc.mint(address(pool), 80e6); // lands late
        assertEq(pool.reserveU(), 4_080e6);
    }

    /// r5: the keeper's float floor stays on Core for buys; others can take only what is above.
    function test_floatFloor() public {
        _setCoreBal(Core.USDC, 200e8);
        vm.prank(keeper);
        pool.setFloatFloor(150e8);
        vm.prank(trader);
        pool.toEvm(0, 200e8);
        assertEq(writer.sent(0), _send(USDC_SYS, 0, 50e8));
        _setCoreBal(Core.USDC, 150e8); // the 50 left Core
        _pastQuiet();
        vm.prank(trader);
        vm.expectRevert(HedgedPool.TooSmall.selector);
        pool.toEvm(0, 200e8); // nothing above the floor
        vm.prank(keeper);
        pool.toEvm(0, 150e8); // the keeper may go below it
        assertEq(writer.sent(1), _send(USDC_SYS, 0, 150e8));
    }

    function test_toEvmDustRefusedForOthers() public {
        _setCoreBal(HYPE, 1e6 + 10e8);
        vm.prank(trader);
        vm.expectRevert(HedgedPool.TooSmall.selector);
        pool.toEvm(1, 0);
    }

    function test_opsFloatIsKeepers() public {
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        pool.fundOps{value: 0.05 ether}();
        assertEq(Core.HYPE_SYSTEM.balance, 0.05 ether);
        assertEq(pool.reserveH(), 100 ether);
    }

    // ------------------------------------------------------------ rebalance

    function test_maxRebalanceDirection() public {
        _setCorePx(42_000_000); // bid 42 after the 10 bp fee 41.958 > pool 40: sell HYPE on Core
        (bool sell, uint256 a) = pool.maxRebalance();
        assertTrue(sell);
        // dh = (41.958·100 − 4000) / (2·41.958) = 2.333 HYPE
        assertApproxEqAbs(a, 2.333 ether, 0.001 ether);

        _setCorePx(38_000_000); // ask 38 after the fee 38.038 < pool 40: buy HYPE on Core
        (sell, a) = pool.maxRebalance();
        assertFalse(sell);
        assertEq(a, 98.1e6); // (4000 − 3803.8) / 2

        _setCorePx(40_000_000); // 39.96 / 40.04 around 40: nothing pays
        (, a) = pool.maxRebalance();
        assertEq(a, 0);
    }

    function test_bridgeBounds() public {
        _setCorePx(38_000_000);
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.WrongDirection.selector);
        pool.bridgeHype(1 ether);

        _setCorePx(42_000_000);
        (, uint256 max) = pool.maxRebalance();
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.TooMuch.selector, max));
        pool.bridgeHype(max + 1);
        vm.expectRevert(HedgedPool.TooSmall.selector);
        pool.bridgeHype(1);
        vm.stopPrank();

        vm.expectRevert(HedgedPool.NotKeeper.selector);
        pool.bridgeHype(1 ether);

        // r4: no rebalance before the keeper has created the Core account
        _setCoreUser(false);
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.NoCoreAccount.selector);
        pool.bridgeHype(1 ether);
    }

    function test_sellFlow() public {
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.bridgeHype(2 ether);
        assertEq(Core.HYPE_SYSTEM.balance, 2 ether, "bridged to 0x2222");

        // quiet while the HYPE moves
        vm.prank(trader);
        vm.expectRevert(HedgedPool.Busy.selector);
        pool.swapHypeForUsdc{value: 1 ether}(0);

        _setCoreBal(HYPE, 1e6 + 2e8); // landed
        _pastQuiet();
        assertEq(pool.reserveH(), 100 ether);
        vm.prank(keeper);
        pool.order(true, 2 ether);
        // sells 2.00 (under the 2.333 cap) at the best bid
        assertEq(writer.sent(0), _order(false, 42e8, 2e8));

        // filled whenever: 2 HYPE on Core became 82.30 USDC on Core; both are counted
        _setCoreBal(HYPE, 1e6);
        _setCoreBal(Core.USDC, 8_230_123_456);
        assertEq(pool.reserveH(), 98 ether);
        assertEq(pool.reserveU(), 4_000e6 + 82_301_234);
        assertGt(pool.poolPx(), 41_600_000);
        assertLt(pool.poolPx(), 42_000_000);
    }

    /// r1/r2: a price reversal blocks the trade; the bridged HYPE stays counted.
    function test_reversalBlocksOrder() public {
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.bridgeHype(2 ether);
        _setCoreBal(HYPE, 1e6 + 2e8);
        _setCorePx(30_000_000);
        _pastQuiet();
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.WrongDirection.selector);
        pool.order(true, 2 ether);
        assertEq(pool.reserveH(), 100 ether);
    }

    /// r2: the IOC runs later; its limit must not cross the pool price. Ticks round away from a loss.
    function test_sellLimitNeverBelowPool() public {
        _setCoreBal(HYPE, 1e6 + 0.3e8); // pool 4000 / 100.3 = 39.880358...
        _setCorePx(40_300_000);
        vm.prank(keeper);
        pool.order(true, 0.3 ether);
        assertEq(writer.sent(0), _order(false, 40.3e8, 0.3e8), "at the bid");

        skip(pool.ORDER_QUIET());
        _setBbo(39_900_000, 40_620_000); // bid above the pool price, but not after the fee
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.WrongDirection.selector);
        pool.order(true, 0.3 ether);
    }

    function test_wideBookRefused() public {
        _setCoreBal(HYPE, 1e6 + 2e8);
        _setBbo(40_000_000, 44_000_000); // 9.52% wide, rounded up
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.WideBook.selector, 953));
        pool.order(true, 2 ether);
    }

    function test_buyWithFloat() public {
        _setCoreBal(Core.USDC, 200e8); // pool 4200/100 = 42 > Core 38
        _setCorePx(38_000_000);
        vm.prank(keeper);
        pool.order(false, 100e6);
        // at the best ask 38; size 100 / 38 = 2.6315 -> 2.63
        assertEq(writer.sent(0), _order(true, 38e8, 2.63e8));

        // filled: 99.94 USDC of float became 2.63 HYPE on Core
        _setCoreBal(HYPE, 1e6 + 2.63e8);
        _setCoreBal(Core.USDC, 100.06e8);
        assertEq(pool.reserveH(), 102.63 ether);

        // anyone brings the HYPE over, once the order quiet has passed
        skip(pool.ORDER_QUIET());
        vm.prank(trader);
        pool.toEvm(2.63e8, 0);
        assertEq(writer.sent(1), _send(Core.HYPE_SYSTEM, HYPE, 2.63e8));
        _setCoreBal(HYPE, 1e6);
        vm.deal(address(pool), 102.63 ether);
        _pastQuiet();
        assertEq(pool.reserveH(), 102.63 ether);
        assertEq(pool.reserveU(), 4_000e6 + 100.06e6);
    }

    function test_buyLimitedToFloat() public {
        _setCoreBal(Core.USDC, 20e8); // pool 4020/100 = 40.2 > Core 38
        _setCorePx(38_000_000);
        vm.prank(keeper);
        pool.order(false, 50e6);
        // spends the 20 USDC on Core: 20 / 38 = 0.526 -> 0.52
        assertEq(writer.sent(0), _order(true, 38e8, 0.52e8));
    }

    /// r7: the mid says buy, but the ask is above the pool price: no trade.
    function test_buyNeedsAskBelowPool() public {
        _setCoreBal(Core.USDC, 400e8); // pool 4400 / 100 = 44.00
        _setBbo(42_600_000, 44_200_000); // mid 43.4 < 44, ask 44.2 > 44
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.WrongDirection.selector);
        pool.order(false, 30e6);
    }

    function test_dustOrderRefused() public {
        _setCoreBal(HYPE, 1e6 + 0.1e8);
        _setCorePx(42_000_000);
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.TooSmall.selector);
        pool.order(true, 0.1 ether); // 4.2 USDC
    }

    // ------------------------------------------------------------ review r6

    /// r6 high: nobody can trade the AMM around a pending order (the sandwich).
    function test_r6_orderQuietBlocksSandwich() public {
        _setCoreBal(HYPE, 1e6 + 2e8);
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.order(true, 2 ether);
        vm.startPrank(trader);
        vm.expectRevert(HedgedPool.Busy.selector);
        pool.swapUsdcForHype(200e6, 0);
        skip(pool.ORDER_QUIET() - 1);
        vm.expectRevert(HedgedPool.Busy.selector);
        pool.swapUsdcForHype(200e6, 0);
        skip(1);
        pool.swapUsdcForHype(200e6, 0);
        vm.stopPrank();
    }

    /// r6 medium: nobody can pull a pending sell's HYPE off Core to make it fail.
    function test_r6_orderQuietBlocksCensoring() public {
        _setCoreBal(HYPE, 1e6 + 2e8);
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.order(true, 2 ether);
        vm.prank(trader);
        vm.expectRevert(HedgedPool.Busy.selector);
        pool.toEvm(2e8, 0);
    }

    /// r6 medium: gas spent on anyone's `toEvm` cannot block bridging: the gate is the account.
    function test_r6_bridgeNeedsAccountNotThreshold() public {
        _setCoreBal(HYPE, 1); // ops float worn down to dust
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.bridgeHype(2 ether);
        assertEq(Core.HYPE_SYSTEM.balance, 2 ether);
    }

    /// r6 medium: the keeper's floor is capped, so payouts never depend on the keeper alone.
    function test_r6_floorCapped() public {
        _setCoreBal(Core.USDC, 1_000e8); // all USDC: 5,000; cap 10% = 500
        vm.prank(keeper);
        pool.setFloatFloor(1_000e8); // tries to protect all of it
        assertEq(pool.effectiveFloor(), 500e8);
        vm.prank(trader);
        pool.toEvm(0, 1_000e8);
        assertEq(writer.sent(0), _send(USDC_SYS, 0, 500e8));
    }

    // ------------------------------------------------------------ review r7

    /// r7 medium: a 40/42 book with the pool at 40. The mid (41) says sell, but selling at the bid
    /// after fees would lose to LPs, so nothing happens.
    function test_r7_midDoesNotAuthorizeALosingSale() public {
        _setCoreBal(HYPE, 1e6 + 1e8); // 1 HYPE on Core to sell
        _setCoreBal(Core.USDC, 40e8); // keeps the pool at 4040 / 101 = 40.00
        _setBbo(40_000_000, 42_000_000);
        assertEq(pool.poolPx(), 40_000_000);
        (, uint256 a) = pool.maxRebalance();
        assertEq(a, 0);
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.WrongDirection.selector);
        pool.order(true, 1 ether);
    }

    /// r7 medium: malformed quotes are rejected, not trusted or panicked on.
    function test_r7_badQuotesRejected() public {
        _setBbo(0, 42_000_000);
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.BadQuote.selector, 0, 42_000_000));
        pool.corePx();
        _setBbo(42_000_000, 41_000_000); // crossed
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.BadQuote.selector, 42_000_000, 41_000_000));
        pool.maxRebalance();
    }

    /// r7 medium: a spoofed one-sided book cannot make a dust `toEvm` look worth 11 USDC.
    function test_r7_toEvmValuesHypeAtCheckedBid() public {
        _setCoreBal(HYPE, 1e6 + 10e8);
        _setBbo(0, 1_000_000_000_000);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.BadQuote.selector, 0, 1_000_000_000_000));
        pool.toEvm(1, 0);
        _setCorePx(40_000_000);
        vm.prank(trader);
        vm.expectRevert(HedgedPool.TooSmall.selector);
        pool.toEvm(1, 0);
    }
}
