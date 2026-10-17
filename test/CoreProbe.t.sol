// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {CoreProbe} from "../src/CoreProbe.sol";

contract RecordingWriter {
    bytes[] public sent;

    function sendRawAction(bytes calldata data) external {
        sent.push(data);
    }

    function count() external view returns (uint256) {
        return sent.length;
    }
}

contract CoreProbeTest is Test {
    CoreProbe probe;
    RecordingWriter writer;

    function setUp() public {
        vm.etch(address(Core.WRITER), address(new RecordingWriter()).code);
        writer = RecordingWriter(address(Core.WRITER));
        probe = new CoreProbe();
    }

    function test_limitOrderBytes() public {
        probe.order(3, true, 100_000e8, 0.0002e8, false, Core.TIF_IOC, 42);
        bytes memory got = writer.sent(0);
        // version 1, action id 1 as three big-endian bytes, then the ABI args
        assertEq(uint8(got[0]), 1);
        assertEq(uint8(got[1]), 0);
        assertEq(uint8(got[2]), 0);
        assertEq(uint8(got[3]), 1);
        assertEq(got.length, 4 + 7 * 32);
        assertEq(
            got,
            abi.encodePacked(
                hex"01000001", abi.encode(uint32(3), true, uint64(100_000e8), uint64(0.0002e8), false, uint8(3), uint128(42))
            )
        );
    }

    function test_otherActionIds() public {
        probe.cancel(3, 42);
        probe.moveUsd(10e6, true);
        probe.sendSpot(address(0xBEEF), 0, 5e8);
        assertEq(writer.sent(0), abi.encodePacked(hex"0100000b", abi.encode(uint32(3), uint128(42))));
        assertEq(writer.sent(1), abi.encodePacked(hex"01000007", abi.encode(uint64(10e6), true)));
        assertEq(
            writer.sent(2), abi.encodePacked(hex"01000006", abi.encode(address(0xBEEF), uint64(0), uint64(5e8)))
        );
    }

    function test_sendAssetBytes() public {
        probe.sendAsset(Core.HYPE_SYSTEM, Core.SPOT_DEX, Core.SPOT_DEX, 1105, 1e7);
        assertEq(
            writer.sent(0),
            abi.encodePacked(
                hex"0100000d",
                abi.encode(Core.HYPE_SYSTEM, address(0), type(uint32).max, type(uint32).max, uint64(1105), uint64(1e7))
            )
        );
        assertEq(Core.systemAddress(0, 1105), 0x2000000000000000000000000000000000000000);
        assertEq(Core.systemAddress(7, 1105), 0x2000000000000000000000000000000000000007);
        assertEq(Core.systemAddress(1105, 1105), Core.HYPE_SYSTEM);
    }

    function test_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(CoreProbe.NotOwner.selector);
        probe.order(3, true, 1, 1, false, Core.TIF_IOC, 0);
        assertEq(writer.count(), 0);
    }

    function test_readsDecode() public {
        vm.mockCall(
            Core.POSITION,
            abi.encode(address(probe), uint16(3)),
            abi.encode(Core.Position(20000, 20e6, 0, 20, false))
        );
        Core.Position memory p = probe.position(3);
        assertEq(p.szi, 20000);
        assertEq(p.leverage, 20);

        vm.mockCall(Core.SPOT_BALANCE, abi.encode(address(probe), uint64(0)), abi.encode(Core.SpotBalance(15e8, 0, 0)));
        assertEq(probe.usdc().total, 15e8);
    }

    function test_readFailsWithoutPrecompile() public {
        // No precompile on a plain EVM: the call succeeds with empty output, which must not pass.
        vm.expectRevert(abi.encodeWithSelector(Core.ReadFailed.selector, Core.SPOT_BALANCE));
        probe.usdc();
    }
}
