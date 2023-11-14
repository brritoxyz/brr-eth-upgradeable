// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BrrETH} from "src/BrrETH.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {IComet} from "src/interfaces/IComet.sol";

contract BrrETHManager {
    using SafeTransferLib for address;

    address private constant _WETH = 0x4200000000000000000000000000000000000006;
    address private constant _COMET =
        0x46e6b214b524310239732D51387075E0e70970bf;
    BrrETH public immutable brrETH;

    error InvalidAmount();
    error InvalidAddress();

    constructor(address _brrETH) {
        brrETH = BrrETH(_brrETH);

        approveTokens();
    }

    function approveTokens() public {
        _WETH.safeApproveWithRetry(_COMET, type(uint256).max);
        _COMET.safeApproveWithRetry(address(brrETH), type(uint256).max);
    }

    /**
     * @notice Deposit ETH for brrETH.
     * @param  to      address  Shares recipient.
     * @return shares  uint256  Shares minted.
     */
    function deposit(address to) external payable returns (uint256) {
        if (msg.value == 0) revert InvalidAmount();
        if (to == address(0)) revert InvalidAddress();

        IWETH(_WETH).deposit{value: msg.value}();

        return _supplyAndDeposit(msg.value, to);
    }

    /**
     * @notice Deposit WETH for brrETH.
     * @param  amount  uint256  WETH amount.
     * @param  to      address  Shares recipient.
     * @return         uint256  Shares minted.
     */
    function deposit(uint256 amount, address to) external returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        if (to == address(0)) revert InvalidAddress();

        _WETH.safeTransferFrom(msg.sender, address(this), amount);

        return _supplyAndDeposit(amount, to);
    }

    /**
     * @notice Redeem brrETH for WETH.
     * @param  shares  uint256  WETH amount.
     * @param  to      address  Shares recipient.
     * @return assets  uint256  Shares minted.
     */
    function redeem(
        uint256 shares,
        address to
    ) external returns (uint256 assets) {
        // Ensure rewards are accrued to maximize redemption amount.
        brrETH.rebase();

        assets = brrETH.redeem(shares, to, msg.sender);

        IComet(_COMET).withdrawTo(to, _WETH, assets);
    }

    function _supplyAndDeposit(
        uint256 amount,
        address to
    ) private returns (uint256) {
        IComet(_COMET).supply(_WETH, amount);

        // Rebase to provide an up-to-date asset/supply base to deposit from.
        brrETH.rebase();

        return brrETH.deposit(_COMET.balanceOf(address(this)), to);
    }
}