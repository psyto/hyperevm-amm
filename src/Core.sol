// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// @notice Writes to HyperCore (CoreWriter actions) and reads it back (precompiles).
/// Writes are fire-and-forget: they run on HyperCore after this EVM block, order actions a few
/// seconds later, with no return value and no revert here if HyperCore rejects them. Reads in the
/// same transaction therefore never see the write.
library Core {
    ICoreWriter internal constant WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    address internal constant POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address internal constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant ACCOUNT_MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;
    address internal constant CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;

    uint24 internal constant LIMIT_ORDER = 1;
    uint24 internal constant SPOT_SEND = 6;
    uint24 internal constant USD_CLASS_TRANSFER = 7;
    uint24 internal constant CANCEL_BY_CLOID = 11;

    uint8 internal constant TIF_ALO = 1;
    uint8 internal constant TIF_GTC = 2;
    uint8 internal constant TIF_IOC = 3;

    uint64 internal constant USDC = 0; // spot token index

    error ReadFailed(address precompile);

    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct MarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    /// Byte 0 = version 1, bytes 1-3 = action id (big-endian), then the ABI-encoded args.
    function encode(uint24 action, bytes memory args) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), action, args);
    }

    /// `limitPx` and `sz` are human values times 1e8. They must still respect the market's tick
    /// and lot size, or HyperCore drops the order silently.
    function limitOrder(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid)
        internal
    {
        WRITER.sendRawAction(
            encode(LIMIT_ORDER, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid))
        );
    }

    function cancelByCloid(uint32 asset, uint128 cloid) internal {
        WRITER.sendRawAction(encode(CANCEL_BY_CLOID, abi.encode(asset, cloid)));
    }

    /// `ntl` in USDC with 6 decimals.
    function usdClassTransfer(uint64 ntl, bool toPerp) internal {
        WRITER.sendRawAction(encode(USD_CLASS_TRANSFER, abi.encode(ntl, toPerp)));
    }

    /// `amountWei` in the token's Core wei decimals (USDC: 8).
    function spotSend(address to, uint64 token, uint64 amountWei) internal {
        WRITER.sendRawAction(encode(SPOT_SEND, abi.encode(to, token, amountWei)));
    }

    function _read(address precompile, bytes memory input) private view returns (bytes memory out) {
        bool ok;
        (ok, out) = precompile.staticcall(input);
        if (!ok || out.length == 0) revert ReadFailed(precompile);
    }

    function position(address user, uint16 perp) internal view returns (Position memory) {
        return abi.decode(_read(POSITION, abi.encode(user, perp)), (Position));
    }

    function spotBalance(address user, uint64 token) internal view returns (SpotBalance memory) {
        return abi.decode(_read(SPOT_BALANCE, abi.encode(user, token)), (SpotBalance));
    }

    function withdrawable(address user) internal view returns (uint64) {
        return abi.decode(_read(WITHDRAWABLE, abi.encode(user)), (uint64));
    }

    function marginSummary(uint32 perpDex, address user) internal view returns (MarginSummary memory) {
        return abi.decode(_read(ACCOUNT_MARGIN_SUMMARY, abi.encode(perpDex, user)), (MarginSummary));
    }

    function oraclePx(uint32 perp) internal view returns (uint64) {
        return abi.decode(_read(ORACLE_PX, abi.encode(perp)), (uint64));
    }

    function userExists(address user) internal view returns (bool) {
        return abi.decode(_read(CORE_USER_EXISTS, abi.encode(user)), (bool));
    }
}
