// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IComet} from "src/interfaces/IComet.sol";
import {ICometRewards} from "src/interfaces/ICometRewards.sol";
import {IRouter} from "src/interfaces/IRouter.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

contract BrrETH is Ownable, ERC4626 {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    string private constant _NAME = "Brrito-Compound WETH";
    string private constant _SYMBOL = "brr-cWETHv3";
    address private constant _WETH = 0x4200000000000000000000000000000000000006;
    address private constant _COMET =
        0x46e6b214b524310239732D51387075E0e70970bf;
    uint256 private constant _FEE_BASE = 10_000;
    uint256 private constant _MAX_REWARD_FEE = 1_000;
    ICometRewards private constant _COMET_REWARDS =
        ICometRewards(0x123964802e6ABabBE1Bc9547D72Ef1B69B00A6b1);
    IRouter private constant _ROUTER =
        IRouter(0x635d91a7fae76BD504fa1084e07Ab3a22495A738);

    // Default reward fee is 5% with a maximum of 10%.
    uint256 public rewardFee = 500;

    // The fee distributor contract for BRR stakers.
    address public feeDistributor = address(0);

    event Harvest(
        address indexed token,
        uint256 rewards,
        uint256 supplyAssets,
        uint256 fees
    );
    event SetRewardFee(uint256);
    event SetFeeDistributor(address);

    error InvalidFeeDistributor();
    error InvalidRewardFee();

    constructor(address initialOwner) {
        feeDistributor = initialOwner;

        _initializeOwner(initialOwner);
        approveTokens();
    }

    function name() public pure override returns (string memory) {
        return _NAME;
    }

    function symbol() public pure override returns (string memory) {
        return _SYMBOL;
    }

    function asset() public pure override returns (address) {
        return _COMET;
    }

    // Approve token allowances for vital contracts.
    function approveTokens() public {
        ICometRewards.RewardConfig memory rewardConfig = _COMET_REWARDS
            .rewardConfig(_COMET);

        // Enable the router to swap our Comet rewards for WETH.
        rewardConfig.token.safeApproveWithRetry(
            address(_ROUTER),
            type(uint256).max
        );

        // Enable Comet to transfer our WETH in exchange for cWETH.
        _WETH.safeApproveWithRetry(_COMET, type(uint256).max);
    }

    /**
     * @notice Returns the maximum amount of assets that can be deposited.
     * @dev    Prevents `msg.sender` from using `type(uint256).max` for `assets`,
     *         which is Comet's alias for "entire balance". Additionally, the
     *         balance check accounts for insufficient balances.
     * @return uint256  Maximum amount of assets that can be deposited.
     */
    function maxDeposit(address) public view override returns (uint256) {
        return _COMET.balanceOf(msg.sender);
    }

    /**
     * @notice Returns the amount of shares that the Vault will exchange for the amount of assets provided,
     *         in an ideal scenario where all conditions are met.
     * @param  assets       uint256  Amount of assets to convert to shares.
     * @param  totalSupply  uint256  Amount of shares in the Vault prior to minting `shares`.
     * @param  totalAssets  uint256  Amount of assets in the Vault prior to transferring in `assets`.
     * @return              uint256  Amount of shares minted in exchange for `assets`.
     */
    function convertToShares(
        uint256 assets,
        uint256 totalSupply,
        uint256 totalAssets
    ) public pure returns (uint256) {
        // Will not realistically overflow since the `totalSupply` and `totalAssets` should never
        // exceed the amount of cWETHv3 that is deposited or received from compounding rewards.
        unchecked {
            return assets.fullMulDiv(totalSupply + 1, totalAssets + 1);
        }
    }

    /**
     * @notice Mints `shares` Vault shares to `to` by depositing `assets` received from supplying ETH.
     * @param  to      address  Address to mint shares to.
     * @return shares  uint256  Amount of shares minted.
     */
    function deposit(address to) external payable returns (uint256 shares) {
        IWETH(_WETH).deposit{value: msg.value}();

        uint256 totalAssetsBefore = totalAssets();

        IComet(_COMET).supply(_WETH, msg.value);

        uint256 assets = totalAssets() - totalAssetsBefore;

        shares = convertToShares(assets, totalSupply(), totalAssetsBefore);

        _mint(to, shares);

        emit Deposit(msg.sender, to, assets, shares);
    }

    /**
     * @notice Mints `shares` Vault shares to `to` by depositing exactly `assets` of underlying tokens.
     * @dev    Comet rounds down transfer amounts, which will result in a 1+ wei discrepancy between `assets`
     *         and the actual amount received by the vault. To err on the side of safety, we are using the
     *         actual amount of assets received by the vault when calculating the amount of shares to mint.
     * @param  assets  uint256  Amount of assets to deposit.
     * @param  to      address  Address to mint shares to.
     * @return shares  uint256  Amount of shares minted.
     */
    function deposit(
        uint256 assets,
        address to
    ) public override returns (uint256 shares) {
        if (assets > maxDeposit(to)) revert DepositMoreThanMax();

        uint256 totalAssetsBefore = totalAssets();

        _COMET.safeTransferFrom(msg.sender, address(this), assets);

        shares = convertToShares(
            // The difference is the precise amount of cWETHv3 received, after rounding down.
            totalAssets() - totalAssetsBefore,
            totalSupply(),
            totalAssetsBefore
        );

        _mint(to, shares);

        emit Deposit(msg.sender, to, assets, shares);
    }

    // Claim rewards and convert them into the vault asset.
    function harvest() public {
        _COMET_REWARDS.claim(_COMET, address(this), true);

        ICometRewards.RewardConfig memory rewardConfig = _COMET_REWARDS
            .rewardConfig(_COMET);
        uint256 rewards = rewardConfig.token.balanceOf(address(this));

        if (rewards == 0) return;

        // Fetching the quote onchain means that we're subject to front/back-running but the
        // assumption is that we will harvest so frequently that the rewards won't justify the effort.
        (uint256 index, uint256 quote) = _ROUTER.getSwapOutput(
            keccak256(abi.encodePacked(rewardConfig.token, _WETH)),
            rewards
        );

        // `swap` returns the entire WETH amount received from the swap.
        uint256 supplyAssets = _ROUTER.swap(
            rewardConfig.token,
            _WETH,
            rewards,
            quote,
            index,
            address(0)
        );

        // Calculate the reward fees, which may be taken out from the output amount before supplying to Comet.
        uint256 fees = supplyAssets.mulDiv(rewardFee, _FEE_BASE);

        // Only distribute rewards if there's enough to split between the owner and the fee distributor.
        if (fees > 1) {
            unchecked {
                // `fees` is a fraction of the swap output so we can safely subtract it without underflowing.
                supplyAssets -= fees;

                uint256 ownerFeeShare = fees / 2;

                _WETH.safeTransfer(owner(), ownerFeeShare);
                _WETH.safeTransfer(feeDistributor, fees - ownerFeeShare);
            }
        }

        emit Harvest(rewardConfig.token, rewards, supplyAssets, fees);

        IComet(_COMET).supply(_WETH, supplyAssets);
    }

    /*//////////////////////////////////////////////////////////////
                        PRIVILEGED SETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the reward fee.
     * @param  _rewardFee  uint256  Reward fee.
     */
    function setRewardFee(uint256 _rewardFee) external onlyOwner {
        if (_rewardFee > _MAX_REWARD_FEE) revert InvalidRewardFee();

        rewardFee = _rewardFee;

        emit SetRewardFee(_rewardFee);
    }

    /**
     * @notice Set the fee distributor.
     * @param  _feeDistributor  uint256  Fee distributor.
     */
    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        if (_feeDistributor == address(0)) revert InvalidFeeDistributor();

        feeDistributor = _feeDistributor;

        emit SetFeeDistributor(_feeDistributor);
    }

    /*//////////////////////////////////////////////////////////////
                    ENFORCE 2-STEP OWNERSHIP TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address) public payable override {}

    function renounceOwnership() public payable override {}

    /*//////////////////////////////////////////////////////////////
                    REMOVED ERC4626 METHODS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address, address, uint256, uint256) internal override {}

    function maxMint(address) public view override returns (uint256) {}

    function maxWithdraw(address) public view override returns (uint256) {}

    function previewMint(uint256) public view override returns (uint256) {}

    function previewWithdraw(uint256) public view override returns (uint256) {}

    function mint(uint256, address) public override returns (uint256) {}

    function withdraw(
        uint256,
        address,
        address
    ) public override returns (uint256) {}
}
