// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// USDC's EVM -> Core path (testnet 0x0B80…C206, mainnet 0x6B9E…0A24).
interface ICoreDepositWallet {
    function deposit(uint256 amount, uint32 destinationDex) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
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
    address internal constant SPOT_PX = 0x0000000000000000000000000000000000000808;
    /// Best bid/ask. Takes the order asset id (spot: 10000 + spot index); not in the official
    /// docs, checked against the testnet book on 2026-10-17.
    address internal constant BBO = 0x000000000000000000000000000000000000080e;
    address internal constant ACCOUNT_MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;
    address internal constant CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;

    uint24 internal constant LIMIT_ORDER = 1;
    uint24 internal constant SPOT_SEND = 6;
    uint24 internal constant USD_CLASS_TRANSFER = 7;
    uint24 internal constant CANCEL_BY_CLOID = 11;
    uint24 internal constant SEND_ASSET = 13;

    /// HYPE sent here on the EVM arrives on Core; HYPE sent here on Core arrives on the EVM.
    address internal constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;
    /// Other tokens: 0x20 followed by the token index (USDC = token 0).
    uint160 internal constant BASE_SYSTEM = uint160(0x2000000000000000000000000000000000000000);
    uint32 internal constant SPOT_DEX = type(uint32).max;

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

    /// Move `amountWei` of `token` between dexes or accounts on Core. Sending to a token's system
    /// address on the spot dex bridges it to the same address on the EVM.
    function sendAsset(address to, uint32 srcDex, uint32 dstDex, uint64 token, uint64 amountWei) internal {
        WRITER.sendRawAction(encode(SEND_ASSET, abi.encode(to, address(0), srcDex, dstDex, token, amountWei)));
    }

    function systemAddress(uint64 token, uint64 hypeToken) internal pure returns (address) {
        return token == hypeToken ? HYPE_SYSTEM : address(BASE_SYSTEM + uint160(token));
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

    /// Last trade price, `8 - szDecimals(base)` decimals. Can sit at one side of a wide book.
    function spotPx(uint64 spotIndex) internal view returns (uint64) {
        return abi.decode(_read(SPOT_PX, abi.encode(spotIndex)), (uint64));
    }

    /// Spot: 8 - szDecimals(base) decimals, like `spotPx`.
    function bbo(uint32 asset) internal view returns (uint64 bid, uint64 ask) {
        return abi.decode(_read(BBO, abi.encode(asset)), (uint64, uint64));
    }

    function userExists(address user) internal view returns (bool) {
        return abi.decode(_read(CORE_USER_EXISTS, abi.encode(user)), (bool));
    }
}
