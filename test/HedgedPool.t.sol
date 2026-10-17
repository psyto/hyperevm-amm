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

        // the pool's Core account holds only the keeper-funded ops float, no USDC float yet
        _setCoreBal(HYPE, 1e6);
        _setCoreBal(Core.USDC, 0);

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

    function _setCorePx(uint64 px6) internal {
        // szDecimals 2 -> Core spot price has 6 decimals
        vm.mockCall(Core.SPOT_PX, abi.encode(SPOT), abi.encode(px6));
    }

    function _setCoreBal(uint64 token, uint64 wei8) internal {
        vm.mockCall(
            Core.SPOT_BALANCE, abi.encode(address(pool), token), abi.encode(Core.SpotBalance(wei8, 0, 0))
        );
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

    /// Sell 2 HYPE at Core 42; the fill leaves 82.30123456 USDC on Core.
    function _sellAndFill() internal {
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.start(true, 2 ether);
        _setCoreBal(HYPE, 1e6 + 2e8);
        vm.prank(keeper);
        pool.order();
        skip(10);
        _setCoreBal(HYPE, 1e6);
        _setCoreBal(Core.USDC, 8_230_123_456);
    }

    // ------------------------------------------------------------ swaps and liquidity

    function test_swapKeepsK() public {
        uint256 k0 = pool.rH() * pool.reserveU();
        vm.prank(trader);
        uint256 out = pool.swapHypeForUsdc{value: 1 ether}(0);
        // 1 HYPE into 100/4000 at 30 bp: a bit under 39.6
        assertApproxEqAbs(out, 39_484_000, 50_000);
        assertGe(pool.rH() * pool.reserveU(), k0);
        assertEq(usdc.balanceOf(address(pool)), pool.rU());
        assertEq(address(pool).balance, pool.rH());
    }

    function test_removeAll() public {
        uint256 s = pool.shares(lp);
        vm.prank(lp);
        (uint256 h, uint256 u) = pool.remove(s, 0, 0);
        assertGt(h, 98.99 ether);
        assertGt(u, 3_959e6);
    }

    /// The Core float counts in prices and shares, but USDC can only be paid out from the EVM.
    function test_floatCountsButPaysFromEvm() public {
        _setCoreBal(Core.USDC, 200e8); // 200 USDC float
        assertEq(pool.reserveU(), 4_200e6);
        assertEq(pool.poolPx(), 42_000_000);

        uint256 s = pool.shares(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.NotEnoughEvmUsdc.selector, 4_000e6));
        pool.remove(s, 0, 0);

        // keeper moves the float to the EVM from Idle
        vm.prank(keeper);
        pool.sendBack(200e8);
        assertEq(writer.sent(0), _send(address(0x2000000000000000000000000000000000000000), 0, 200e8));
        assertEq(pool.expectU(), 4_200e6);
        _setCoreBal(Core.USDC, 0);
        usdc.mint(address(pool), 200e6);
        vm.prank(keeper);
        pool.finish();

        vm.prank(lp);
        (, uint256 u) = pool.remove(s, 0, 0);
        assertGt(u, 4_157e6); // 99% of 4,200
    }

    // ------------------------------------------------------------ rebalance math

    function test_maxRebalanceDirection() public {
        _setCorePx(42_000_000); // Core 42 > pool 40: pool is cheap, sell HYPE on Core
        (bool sell, uint256 a) = pool.maxRebalance();
        assertTrue(sell);
        // dh = (42·100 − 4000) / 84 = 2.381 HYPE
        assertApproxEqAbs(a, 2.381 ether, 0.001 ether);

        _setCorePx(38_000_000); // Core 38 < pool 40: buy HYPE on Core
        (sell, a) = pool.maxRebalance();
        assertFalse(sell);
        // du = (4000 − 3800) / 2 = 100 USDC
        assertEq(a, 100e6);

        _setCorePx(40_000_000);
        (, a) = pool.maxRebalance();
        assertEq(a, 0);
    }

    function test_startBounds() public {
        _setCorePx(42_000_000);
        vm.startPrank(keeper);
        vm.expectRevert(HedgedPool.WrongDirection.selector);
        pool.start(false, 20e6);
        (, uint256 max) = pool.maxRebalance();
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.TooMuch.selector, max));
        pool.start(true, max + 1);
        vm.expectRevert(HedgedPool.TooSmall.selector);
        pool.start(true, 1);
        vm.stopPrank();

        vm.expectRevert(HedgedPool.NotKeeper.selector);
        pool.start(true, 1 ether);
    }

    // ------------------------------------------------------------ selling HYPE: proceeds become float

    function test_sellKeepsProceedsAsFloat() public {
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.start(true, 2 ether);
        assertEq(Core.HYPE_SYSTEM.balance, 2 ether, "bridged to 0x2222");
        assertEq(pool.rH(), 98 ether);

        // paused while in flight
        vm.prank(trader);
        vm.expectRevert(HedgedPool.Busy.selector);
        pool.swapHypeForUsdc{value: 1 ether}(0);

        // nothing on Core yet: only the ops float
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.NotYet.selector);
        pool.order();

        _setCoreBal(HYPE, 1e6 + 2e8);
        vm.prank(keeper);
        pool.order();
        // sells 2.00 (under the 2.381 cap); limit 42 × 0.99 = 41.58
        assertEq(writer.sent(0), _order(false, 41.58e8, 2e8));

        vm.prank(keeper);
        vm.expectRevert(HedgedPool.NotYet.selector);
        pool.sendBack(0);

        skip(10);
        _setCoreBal(HYPE, 1e6);
        _setCoreBal(Core.USDC, 8_230_123_456);
        vm.startPrank(keeper);
        pool.sendBack(0); // keep it all on Core
        assertEq(writer.count(), 1, "nothing to send");
        pool.finish();
        vm.stopPrank();

        assertEq(pool.rH(), 98 ether);
        assertEq(pool.rU(), 4_000e6);
        assertEq(pool.reserveU(), 4_000e6 + 82_301_234);
        // pool price moved from 40.00 toward Core 42 without passing it
        assertGt(pool.poolPx(), 41_600_000);
        assertLt(pool.poolPx(), 42_000_000);
    }

    function test_sellBringsPartBack() public {
        _sellAndFill();
        vm.prank(keeper);
        pool.sendBack(40e8);
        assertEq(writer.sent(1), _send(address(0x2000000000000000000000000000000000000000), 0, 40e8));
        assertEq(pool.expectU(), 4_040e6);
        assertEq(pool.floatAfter(), 4_230_123_456);

        _setCoreBal(Core.USDC, 4_230_123_456);
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.NotYet.selector);
        pool.finish();
        usdc.mint(address(pool), 40e6);
        vm.prank(keeper);
        pool.finish();
        assertEq(pool.rU(), 4_040e6);
        assertEq(pool.reserveU(), 4_040e6 + 42_301_234);
    }

    // ------------------------------------------------------------ buying HYPE with the float

    function test_buyWithFloat() public {
        _setCoreBal(Core.USDC, 200e8); // pool 4200/100 = 42 > Core 38
        _setCorePx(38_000_000);
        // du = (4200 − 3800) / 2 = 200
        vm.prank(keeper);
        pool.start(false, 100e6);
        assertEq(pool.rU(), 4_000e6, "nothing left the EVM");

        vm.prank(keeper);
        pool.order();
        // limit 38 × 1.01 = 38.38; size 100 / 38.38 = 2.6055 -> 2.60
        assertEq(writer.sent(0), _order(true, 38.38e8, 2.6e8));

        skip(10);
        _setCoreBal(HYPE, 1e6 + 2.6e8);
        _setCoreBal(Core.USDC, 100.2e8);
        vm.prank(keeper);
        pool.sendBack(0);
        assertEq(writer.sent(1), _send(Core.HYPE_SYSTEM, HYPE, 2.6e8));
        assertEq(pool.expectH(), 102.6 ether);

        vm.deal(address(pool), 102.6 ether); // Core -> EVM credit, no call
        vm.prank(keeper);
        pool.finish();
        assertEq(pool.rH(), 102.6 ether);
        assertEq(pool.reserveU(), 4_000e6 + 100.2e6);
    }

    function test_buyLimitedToFloat() public {
        _setCoreBal(Core.USDC, 20e8); // 20 USDC float; pool 4020/100 = 40.2 > Core 38
        _setCorePx(38_000_000);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.TooMuch.selector, 20e6));
        pool.start(false, 50e6);
    }

    function test_tickRounding() public {
        // 41.854 × 0.99 = 41.43546 -> 5 significant figures, rounded up for a sell -> 41.436
        _setCorePx(41_854_000);
        vm.prank(keeper);
        pool.start(true, 1 ether);
        _setCoreBal(HYPE, 1e6 + 1e8);
        vm.prank(keeper);
        pool.order();
        assertEq(writer.sent(0), _order(false, 41.436e8, 1e8));
    }

    // ------------------------------------------------------------ review r1 (fixed, kept)

    /// r1 high: a HYPE bridge that never arrives no longer freezes the pool forever.
    function test_r1_stuckBridgeCanBeGivenUp() public {
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.start(true, 2 ether);
        vm.startPrank(keeper);
        vm.expectRevert(HedgedPool.NotYet.selector);
        pool.sendBack(0); // too early to give up
        skip(pool.STUCK_DELAY());
        pool.sendBack(0);
        pool.finish();
        vm.stopPrank();
        assertEq(uint8(pool.stage()), 0);
        assertEq(pool.rH(), 98 ether, "loss recognised");
        uint256 s = pool.shares(lp);
        vm.prank(lp);
        pool.remove(s, 0, 0);
    }

    /// r1 high: a price reversal after `start` blocks the trade; the HYPE comes home untraded.
    function test_r1_reversalReturnsUntraded() public {
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.start(true, 2 ether);
        _setCorePx(30_000_000);
        _setCoreBal(HYPE, 1e6 + 2e8);
        vm.startPrank(keeper);
        vm.expectRevert(HedgedPool.WrongDirection.selector);
        pool.order();
        pool.sendBack(0);
        vm.stopPrank();
        assertEq(pool.expectH(), 100 ether);
        vm.deal(address(pool), 100 ether);
        vm.prank(keeper);
        pool.finish();
        assertEq(pool.rH(), 100 ether);
        assertEq(writer.count(), 1, "only the HYPE send, no order");
    }

    /// r1 medium: a retry while a credit is pending keeps it owed; a dropped send is resent.
    function test_r1_retryKeepsPendingCredit() public {
        _sellAndFill();
        vm.prank(keeper);
        pool.sendBack(8_230_123_456);
        assertEq(pool.expectU(), 4_082_301_234);

        vm.prank(keeper);
        vm.expectRevert(HedgedPool.NotYet.selector);
        pool.sendBack(0); // same block: Core has not processed the first send yet

        vm.roll(block.number + 1);
        _setCoreBal(Core.USDC, 56); // debited on Core (dust left), not yet credited on the EVM
        vm.startPrank(keeper);
        pool.sendBack(0);
        assertEq(writer.count(), 2, "nothing resent");
        assertEq(pool.expectU(), 4_082_301_234, "still owed");
        vm.expectRevert(HedgedPool.NotYet.selector);
        pool.finish();
        vm.stopPrank();

        usdc.mint(address(pool), 82_301_234);
        vm.prank(keeper);
        pool.finish();
        assertEq(pool.rU(), 4_082_301_234);
    }

    function test_r1_droppedSendIsResent() public {
        _sellAndFill();
        vm.prank(keeper);
        pool.sendBack(40e8);
        vm.roll(block.number + 1);
        // Core still shows the full balance: the send was dropped
        vm.prank(keeper);
        pool.sendBack(0);
        assertEq(writer.sent(2), _send(address(0x2000000000000000000000000000000000000000), 0, 40e8));
        assertEq(pool.expectU(), 4_040e6, "unchanged by the retry");
    }

    /// r1 low: the Core HYPE float is keeper-funded, outside the reserves.
    function test_r1_opsFloatIsKeepers() public {
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        pool.fundOps{value: 0.05 ether}();
        assertEq(Core.HYPE_SYSTEM.balance, 0.05 ether);
        assertEq(pool.rH(), 100 ether);
        assertEq(address(pool).balance, 100 ether);
    }

    // ------------------------------------------------------------ review r2

    /// r2 high: the IOC runs seconds after `order`; its limit must not cross the pool price.
    function test_r2_sellLimitNeverBelowPool() public {
        _setCorePx(40_300_000); // 0.75% above the 40.00 pool price; Core − 1% would be 39.897
        vm.prank(keeper);
        pool.start(true, 0.3 ether);
        _setCoreBal(HYPE, 1e6 + 0.3e8);
        vm.prank(keeper);
        pool.order();
        assertEq(writer.sent(0), _order(false, 40e8, 0.3e8));
    }

    function test_r2_buyLimitNeverAbovePool() public {
        _setCoreBal(Core.USDC, 200e8); // pool 42.00; Core 41.7 + 1% would be 42.117
        _setCorePx(41_700_000);
        vm.prank(keeper);
        pool.start(false, 12e6);
        vm.prank(keeper);
        pool.order();
        // limit capped at 42.00; 12 / 42 = 0.2857 -> 0.28
        assertEq(writer.sent(0), _order(true, 42e8, 0.28e8));
    }

    /// r2 high (late bridge): HYPE that lands on Core after the bridge was given up is brought
    /// back by `sendBack` from Idle and re-enters the reserves.
    function test_r2_lateHypeRecoveredFromIdle() public {
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.start(true, 2 ether);
        skip(pool.STUCK_DELAY());
        vm.startPrank(keeper);
        pool.sendBack(0);
        pool.finish();
        assertEq(pool.rH(), 98 ether);

        _setCoreBal(HYPE, 1e6 + 2e8); // the bridge lands late
        pool.sendBack(0);
        assertEq(writer.sent(0), _send(Core.HYPE_SYSTEM, HYPE, 2e8));
        assertEq(pool.expectH(), 100 ether);
        vm.deal(address(pool), 100 ether);
        pool.finish();
        vm.stopPrank();
        assertEq(pool.rH(), 100 ether);
    }

    // ------------------------------------------------------------ review r3

    /// r3 high: an IOC that fills after the round closed is still in the books, because Core
    /// balances count on both sides.
    function test_r3_lateFillAfterFinishStaysInTheBooks() public {
        _setCoreBal(Core.USDC, 200e8);
        _setCorePx(38_000_000);
        vm.startPrank(keeper);
        pool.start(false, 100e6);
        pool.order();
        skip(10);
        pool.sendBack(0); // the IOC has not run yet: Core unchanged
        pool.finish();
        vm.stopPrank();
        assertEq(pool.reserveH(), 100 ether);
        assertEq(pool.reserveU(), 4_200e6);

        // the IOC runs now: 100 USDC of float become 2.6 HYPE on Core
        _setCoreBal(HYPE, 1e6 + 2.6e8);
        _setCoreBal(Core.USDC, 100.2e8);
        assertEq(pool.reserveH(), 102.6 ether);
        assertEq(pool.reserveU(), 4_100.2e6);

        // a trader gets exactly the reconciled quote
        uint256 hIn = 1 ether * 9970;
        uint256 reconciled = hIn * 4_100.2e6 / (102.6 ether * 10_000 + hIn);
        vm.prank(trader);
        uint256 out = pool.swapHypeForUsdc{value: 1 ether}(0);
        assertEq(out, reconciled);
    }

    /// r3 medium: a float sent to the pool's Core account before anyone minted cannot be
    /// captured by a stranger minting first.
    function test_r3_firstMintIsKeepers() public {
        HedgedPool fresh = new HedgedPool(IERC20(address(usdc)), keeper, HYPE, SPOT, 2);
        vm.mockCall(
            Core.SPOT_BALANCE, abi.encode(address(fresh), Core.USDC), abi.encode(Core.SpotBalance(500e8, 0, 0))
        );
        vm.startPrank(trader);
        usdc.approve(address(fresh), type(uint256).max);
        vm.expectRevert(HedgedPool.NotKeeper.selector);
        fresh.add{value: 0.01 ether}(11e6, 0);
        vm.stopPrank();
    }

    /// HYPE on Core counts, but HYPE is paid out only from the EVM.
    function test_r3_coreHypePaysFromEvm() public {
        _setCoreBal(HYPE, 1e6 + 10e8); // 10 HYPE on Core
        assertEq(pool.reserveH(), 110 ether);
        uint256 s = pool.shares(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.NotEnoughEvmHype.selector, 100 ether));
        pool.remove(s, 0, 0);
    }
}
