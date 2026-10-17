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

/// Pulls USDC like Circle's CoreDepositWallet and remembers the last deposit.
contract MockDepositWallet {
    MockUSDC immutable usdc;
    uint256 public lastAmount;
    uint32 public lastDex;

    constructor(MockUSDC u) {
        usdc = u;
    }

    function deposit(uint256 amount, uint32 dex) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
        lastDex = dex;
    }
}

contract HedgedPoolTest is Test {
    uint64 constant HYPE = 1105;
    uint64 constant SPOT = 1035;

    HedgedPool pool;
    MockUSDC usdc;
    MockDepositWallet dw;
    RecordingWriter writer;
    address keeper = address(0xCEE9);
    address lp = address(0x11F);
    address trader = address(0x7AD);

    function setUp() public {
        vm.etch(address(Core.WRITER), address(new RecordingWriter()).code);
        writer = RecordingWriter(address(Core.WRITER));
        usdc = new MockUSDC();
        dw = new MockDepositWallet(usdc);
        pool = new HedgedPool(IERC20(address(usdc)), address(dw), keeper, HYPE, SPOT, 2);

        // 100 HYPE + 4,000 USDC: pool price 40.00
        vm.deal(lp, 1000 ether);
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(pool), type(uint256).max);
        pool.add{value: 100 ether}(4_000e6, 0);
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

    // ------------------------------------------------------------ swaps and liquidity

    function test_swapKeepsK() public {
        uint256 k0 = pool.rH() * pool.rU();
        vm.prank(trader);
        uint256 out = pool.swapHypeForUsdc{value: 1 ether}(0);
        // 1 HYPE into 100/4000 at 30 bp: a bit under 39.6
        assertApproxEqAbs(out, 39_484_000, 50_000);
        assertGe(pool.rH() * pool.rU(), k0);
        assertEq(usdc.balanceOf(address(pool)), pool.rU());
        assertEq(address(pool).balance, pool.rH());
    }

    function test_removeAll() public {
        uint256 s = pool.shares(lp);
        vm.prank(lp);
        (uint256 h, uint256 u) = pool.remove(s, 0, 0);
        assertGt(h, 99.99 ether);
        assertGt(u, 3_999e6);
    }

    // ------------------------------------------------------------ rebalance math

    function test_maxRebalanceDirection() public {
        _setCorePx(42_000_000); // Core 42 > pool 40: pool is cheap, sell HYPE on Core
        (bool sell, uint256 a) = pool.maxRebalance();
        assertTrue(sell);
        // dh = (42·100 − 4000) / 84 = 2.381 HYPE
        assertApproxEqAbs(a, 2.381 ether, 0.001 ether);

        _setCorePx(38_000_000); // Core 38 < pool 40: buy HYPE on Core with USDC
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
        pool.start(false, 1e6);
        (, uint256 max) = pool.maxRebalance();
        vm.expectRevert(abi.encodeWithSelector(HedgedPool.TooMuch.selector, max));
        pool.start(true, max + 1);
        vm.stopPrank();

        vm.expectRevert(HedgedPool.NotKeeper.selector);
        pool.start(true, 1 ether);
    }

    // ------------------------------------------------------------ full cycle, selling HYPE

    function test_cycleSellHype() public {
        _setCorePx(42_000_000);
        vm.prank(keeper);
        pool.start(true, 2 ether);
        assertEq(Core.HYPE_SYSTEM.balance, 2 ether, "bridged to 0x2222");
        assertEq(pool.rH(), 98 ether);

        // paused while in flight
        vm.prank(trader);
        vm.expectRevert(HedgedPool.Busy.selector);
        pool.swapHypeForUsdc{value: 1 ether}(0);

        // nothing on Core yet
        _setCoreBal(HYPE, 0);
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.NotYet.selector);
        pool.order();

        // 2 HYPE arrived, minus a 1 USDC activation fee taken in HYPE (0.0238)
        _setCoreBal(HYPE, 197_619_048);
        vm.prank(keeper);
        pool.order();
        // sells (1.97619048 − 0.01) rounded to the 0.01 lot = 1.96; limit 42 × 0.99 = 41.58
        assertEq(
            writer.sent(0),
            abi.encodePacked(
                hex"01000001",
                abi.encode(uint32(11035), false, uint64(41.58e8), uint64(1.96e8), false, uint8(3), uint128(0))
            )
        );

        vm.prank(keeper);
        vm.expectRevert(HedgedPool.NotYet.selector);
        pool.sendBack();

        // filled at 42 less fees: 82.30 USDC; HYPE left 0.01619048
        skip(10);
        _setCoreBal(HYPE, 1_619_048);
        _setCoreBal(Core.USDC, 8_230_123_456);
        vm.prank(keeper);
        pool.sendBack();
        assertEq(
            writer.sent(1),
            abi.encodePacked(
                hex"0100000d",
                abi.encode(Core.HYPE_SYSTEM, address(0), type(uint32).max, type(uint32).max, HYPE, uint64(619_048))
            )
        );
        assertEq(
            writer.sent(2),
            abi.encodePacked(
                hex"0100000d",
                abi.encode(
                    address(0x2000000000000000000000000000000000000000),
                    address(0),
                    type(uint32).max,
                    type(uint32).max,
                    uint64(0),
                    uint64(8_230_123_400)
                )
            )
        );

        // credits have not landed yet
        vm.prank(keeper);
        vm.expectRevert(HedgedPool.NotYet.selector);
        pool.finish();

        // Core -> EVM: balance appears without a call
        vm.deal(address(pool), address(pool).balance + 619_048 * 1e10);
        usdc.mint(address(pool), 82_301_234);
        vm.prank(keeper);
        pool.finish();

        assertEq(uint8(pool.stage()), 0);
        assertEq(pool.rH(), 98 ether + 619_048 * 1e10);
        assertEq(pool.rU(), 4_000e6 + 82_301_234);
        // pool price moved from 40.00 toward Core 42 without passing it
        assertGt(pool.poolPx(), 41_600_000);
        assertLt(pool.poolPx(), 42_000_000);
    }

    // ------------------------------------------------------------ full cycle, buying HYPE

    function test_cycleBuyHype() public {
        _setCorePx(38_000_000);
        vm.prank(keeper);
        pool.start(false, 100e6);
        assertEq(dw.lastAmount(), 100e6);
        assertEq(dw.lastDex(), type(uint32).max, "spot dex");
        assertEq(pool.rU(), 3_900e6);

        _setCoreBal(Core.USDC, 100e8);
        vm.prank(keeper);
        pool.order();
        // limit 38 × 1.01 = 38.38; size 100 / 38.38 = 2.6055 -> 2.60
        assertEq(
            writer.sent(0),
            abi.encodePacked(
                hex"01000001",
                abi.encode(uint32(11035), true, uint64(38.38e8), uint64(2.6e8), false, uint8(3), uint128(0))
            )
        );
    }

    function test_tickRounding() public {
        // 41.854 × 0.99 = 41.43546 -> 5 significant figures -> 41.435
        _setCorePx(41_854_000);
        vm.prank(keeper);
        // pool 40 < Core 41.854: sell HYPE
        pool.start(true, 1 ether);
        _setCoreBal(HYPE, 1e8);
        vm.prank(keeper);
        pool.order();
        assertEq(
            writer.sent(0),
            abi.encodePacked(
                hex"01000001",
                abi.encode(uint32(11035), false, uint64(41.435e8), uint64(0.99e8), false, uint8(3), uint128(0))
            )
        );
    }
}
