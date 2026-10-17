// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Core, ICoreDepositWallet, IERC20} from "./Core.sol";

/// @notice Step 0 of the AMM: a contract that holds a HyperCore account, sends orders to it
/// through CoreWriter, and reads the result back through the precompiles in a later block.
/// The contract address is its own HyperCore account; fund it by sending USDC on HyperCore to it.
contract CoreProbe {
    address public immutable owner;

    event Sent(uint24 indexed action, bytes data);
    event Received(address indexed from, uint256 amount);

    error NotOwner();

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function order(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid)
        external
        onlyOwner
    {
        Core.limitOrder(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid);
        emit Sent(Core.LIMIT_ORDER, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid));
    }

    function cancel(uint32 asset, uint128 cloid) external onlyOwner {
        Core.cancelByCloid(asset, cloid);
        emit Sent(Core.CANCEL_BY_CLOID, abi.encode(asset, cloid));
    }

    function moveUsd(uint64 ntl, bool toPerp) external onlyOwner {
        Core.usdClassTransfer(ntl, toPerp);
        emit Sent(Core.USD_CLASS_TRANSFER, abi.encode(ntl, toPerp));
    }

    /// Send spot tokens on HyperCore back to `to` (USDC wei has 8 decimals).
    function sendSpot(address to, uint64 token, uint64 amountWei) external onlyOwner {
        Core.spotSend(to, token, amountWei);
        emit Sent(Core.SPOT_SEND, abi.encode(to, token, amountWei));
    }

    /// Core -> EVM, or between Core accounts/dexes (action 13).
    function sendAsset(address to, uint32 srcDex, uint32 dstDex, uint64 token, uint64 amountWei) external onlyOwner {
        Core.sendAsset(to, srcDex, dstDex, token, amountWei);
        emit Sent(Core.SEND_ASSET, abi.encode(to, srcDex, dstDex, token, amountWei));
    }

    /// EVM -> Core for HYPE: a plain transfer to the system address.
    function hypeToCore(uint256 amount) external onlyOwner {
        (bool ok,) = Core.HYPE_SYSTEM.call{value: amount}("");
        require(ok, "hype bridge");
    }

    /// EVM -> Core for USDC: through the deposit wallet, landing on the spot dex.
    function usdcToCore(address usdcToken, address depositWallet, uint256 amount) external onlyOwner {
        IERC20(usdcToken).approve(depositWallet, amount);
        ICoreDepositWallet(depositWallet).deposit(amount, Core.SPOT_DEX);
    }

    /// Return EVM-side funds to the owner.
    function sweep(address token) external onlyOwner {
        if (token == address(0)) {
            (bool ok,) = owner.call{value: address(this).balance}("");
            require(ok, "sweep");
        } else {
            IERC20(token).transfer(owner, IERC20(token).balanceOf(address(this)));
        }
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function spotBalance(uint64 token) external view returns (Core.SpotBalance memory) {
        return Core.spotBalance(address(this), token);
    }

    function position(uint16 perp) external view returns (Core.Position memory) {
        return Core.position(address(this), perp);
    }

    function usdc() external view returns (Core.SpotBalance memory) {
        return Core.spotBalance(address(this), Core.USDC);
    }

    function withdrawable() external view returns (uint64) {
        return Core.withdrawable(address(this));
    }

    function margin() external view returns (Core.MarginSummary memory) {
        return Core.marginSummary(0, address(this));
    }

    function exists() external view returns (bool) {
        return Core.userExists(address(this));
    }
}
