// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

/**
 * @title OUSD Vault Admin Contract
 * @notice The VaultAdmin contract makes configuration and admin calls on the vault.
 * @author Origin Protocol Inc
 */

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { StableMath } from "../utils/StableMath.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { Pausable } from "../pausing/Pausable.sol";
import "./VaultStorage.sol";

contract VaultAdmin is VaultStorage, Pausable {
    using SafeERC20 for IERC20;
    using StableMath for uint256;

    /**
     * @dev Verifies that the caller is the Vault, Governor, or Strategist.
     */
    modifier onlyVaultOrGovernorOrStrategist() {
        require(
            msg.sender == address(this) ||
            _isGovernorOrStrategist(),
        "Caller is not the Vault, Governor, or Strategist"
        );
        _;
    }

    modifier onlyGovernorOrStrategist() {
        require(
            _isGovernorOrStrategist(),
            "Caller is not the Strategist or Governor"
        );
        _;
    }

    modifier onlyPauserOrGovernorOrStrategist() {
        require(
            msg.sender == _pauser || _isGovernorOrStrategist(),
            "Caller is not the Pauser or Strategist or Governor"
        );
        _;
    }

    modifier onlyPauserOrGovernor() {
        require(
            msg.sender == _pauser || isGovernor(),
            "Caller is not the Pauser or Governor"
        );
        _;
    }

    /***************************************
                 Configuration
    ****************************************/

    /**
     * @dev Set address of price provider.
     * @param _priceProvider Address of price provider
     */
    function setPriceProvider(address _priceProvider) external onlyGovernor {
        priceProvider = _priceProvider;
        emit PriceProviderUpdated(_priceProvider);
    }

    /**
     * @dev Set a fee in basis points to be charged for a redeem.
     * @param _redeemFeeBps Basis point fee to be charged
     */
    function setRedeemFeeBps(uint256 _redeemFeeBps) external onlyGovernor {
        require(_redeemFeeBps <= 1000, "Redeem fee should not be over 10%");
        redeemFeeBps = _redeemFeeBps;
        emit RedeemFeeUpdated(_redeemFeeBps);
    }

    /**
     * @dev Set a buffer of assets to keep in the Vault to handle most
     * redemptions without needing to spend gas unwinding assets from a Strategy.
     * @param _vaultBuffer Percentage using 18 decimals. 100% = 1e18.
     */
    function setVaultBuffer(uint256 _vaultBuffer)
        external
        onlyGovernorOrStrategist
    {
        require(_vaultBuffer <= 1e18, "Invalid value");
        vaultBuffer = _vaultBuffer;
        emit VaultBufferUpdated(_vaultBuffer);
    }

    /**
     * @dev Sets the minimum amount of OUSD in a mint to trigger an
     * automatic allocation of funds afterwords.
     * @param _threshold OUSD amount with 18 fixed decimals.
     */
    function setAutoAllocateThreshold(uint256 _threshold)
        external
        onlyGovernor
    {
        autoAllocateThreshold = _threshold;
        emit AllocateThresholdUpdated(_threshold);
    }

    /**
     * @dev Set a minimum amount of OUSD in a mint or redeem that triggers a
     * rebase
     * @param _threshold OUSD amount with 18 fixed decimals.
     */
    function setRebaseThreshold(uint256 _threshold) external onlyGovernor {
        rebaseThreshold = _threshold;
        emit RebaseThresholdUpdated(_threshold);
    }

    /**
     * @dev Set address of Strategist
     * @param _address Address of Strategist
     */
    function setStrategistAddr(address _address) external onlyGovernor {
        strategistAddr = _address;
        emit StrategistUpdated(_address);
    }

    /**
     * @dev Set the default Strategy for an asset, i.e. the one which the asset
            will be automatically allocated to and withdrawn from
     * @param _asset Address of the asset
     * @param _strategy Address of the Strategy
     */
    function setAssetDefaultStrategy(address _asset, address _strategy)
        external
        onlyGovernorOrStrategist
    {
        emit AssetDefaultStrategyUpdated(_asset, _strategy);
        // If its a zero address being passed for the strategy we are removing
        // the default strategy
        if (_strategy != address(0)) {
            // Make sure the strategy meets some criteria
            require(strategies[_strategy].isSupported, "Strategy not approved");
            IStrategy strategy = IStrategy(_strategy);
            require(assets[_asset].isSupported, "Asset is not supported");
            require(
                strategy.supportsAsset(_asset),
                "Asset not supported by Strategy"
            );
        }
        assetDefaultStrategies[_asset] = _strategy;
    }

    /**
     * @dev Add a supported asset to the contract, i.e. one that can be
     *         to mint OUSD.
     * @param _asset Address of asset
     */
    function supportAsset(address _asset) external onlyGovernor {
        require(!assets[_asset].isSupported, "Asset already supported");

        assets[_asset] = Asset({ isSupported: true });
        allAssets.push(_asset);

        // Verify that our oracle supports the asset
        // slither-disable-next-line unused-return
        IOracle(priceProvider).price(_asset);

        emit AssetSupported(_asset);
    }

    /**
     * @dev Add a strategy to the Vault.
     * @param _addr Address of the strategy to add
     */
    function approveStrategy(address _addr) external onlyGovernor {
        require(!strategies[_addr].isSupported, "Strategy already approved");
        strategies[_addr] = Strategy({ isSupported: true, _deprecated: 0 });
        allStrategies.push(_addr);
        emit StrategyApproved(_addr);
    }

    /**
     * @dev Remove a strategy from the Vault.
     * @param _addr Address of the strategy to remove
     */

    function removeStrategy(address _addr) external onlyGovernor {
        require(strategies[_addr].isSupported, "Strategy not approved");

        for (uint256 i = 0; i < allAssets.length; i++) {
            require(
                assetDefaultStrategies[allAssets[i]] != _addr,
                "Strategy is default for an asset"
            );
        }

        // Initialize strategyIndex with out of bounds result so function will
        // revert if no valid index found
        uint256 strategyIndex = allStrategies.length;
        for (uint256 i = 0; i < allStrategies.length; i++) {
            if (allStrategies[i] == _addr) {
                strategyIndex = i;
                break;
            }
        }

        if (strategyIndex < allStrategies.length) {
            allStrategies[strategyIndex] = allStrategies[
                allStrategies.length - 1
            ];
            allStrategies.pop();

            // Mark the strategy as not supported
            strategies[_addr].isSupported = false;

            // Withdraw all assets
            IStrategy strategy = IStrategy(_addr);
            strategy.withdrawAll();

            emit StrategyRemoved(_addr);
        }
    }

    /**
     * @notice Move assets from one Strategy to another
     * @param _strategyFromAddress Address of Strategy to move assets from.
     * @param _strategyToAddress Address of Strategy to move assets to.
     * @param _assets Array of asset address that will be moved
     * @param _amounts Array of amounts of each corresponding asset to move.
     */
    function reallocate(
        address _strategyFromAddress,
        address _strategyToAddress,
        address[] calldata _assets,
        uint256[] calldata _amounts
    ) external onlyGovernorOrStrategist {
        require(
            strategies[_strategyFromAddress].isSupported,
            "Invalid from Strategy"
        );
        require(
            strategies[_strategyToAddress].isSupported,
            "Invalid to Strategy"
        );
        require(_assets.length == _amounts.length, "Parameter length mismatch");

        IStrategy strategyFrom = IStrategy(_strategyFromAddress);
        IStrategy strategyTo = IStrategy(_strategyToAddress);

        for (uint256 i = 0; i < _assets.length; i++) {
            require(strategyTo.supportsAsset(_assets[i]), "Asset unsupported");
            // Withdraw from Strategy and pass other Strategy as recipient
            strategyFrom.withdraw(address(strategyTo), _assets[i], _amounts[i]);
        }
        // Tell new Strategy to deposit into protocol
        strategyTo.depositAll();
    }

    /**
     * @dev Sets the maximum allowable difference between
     * total supply and backing assets' value.
     */
    function setMaxSupplyDiff(uint256 _maxSupplyDiff) external onlyGovernor {
        maxSupplyDiff = _maxSupplyDiff;
        emit MaxSupplyDiffChanged(_maxSupplyDiff);
    }

    /**
     * @dev Sets the trusteeAddress that can receive a portion of yield.
     *      Setting to the zero address disables this feature.
     */
    function setTrusteeAddress(address _address) external onlyGovernor {
        trusteeAddress = _address;
        emit TrusteeAddressChanged(_address);
    }

    /**
     * @dev Sets the TrusteeFeeBps to the percentage of yield that should be
     *      received in basis points.
     */
    function setTrusteeFeeBps(uint256 _basis) external onlyGovernor {
        require(_basis <= 5000, "basis cannot exceed 50%");
        trusteeFeeBps = _basis;
        emit TrusteeFeeBpsChanged(_basis);
    }

    /***************************************
                    Pause
    ****************************************/

    /**
     * @dev Set the address of the pauser contract
     */
    function setPauser(address __pauser) external onlyGovernor {
        _pauser = __pauser;
        emit PauserChanged(__pauser);
    }

    /**
     * @dev Set the deposit paused flag to true to prevent rebasing.
     */
    function pauseRebase() public onlyPauserOrGovernorOrStrategist {
        rebasePaused = true;
        emit RebasePaused();
    }

    /**
     * @dev Set the deposit paused flag to true to allow rebasing.
     */
    function unpauseRebase() public onlyPauserOrGovernor {
        rebasePaused = false;
        emit RebaseUnpaused();
    }

    /**
     * @dev Set the deposit paused flag to true to prevent capital movement.
     */
    function pauseCapital() public onlyPauserOrGovernorOrStrategist {
        capitalPaused = true;
        emit CapitalPaused();
    }

    /**
     * @dev Set the deposit paused flag to false to enable capital movement.
     */
    function unpauseCapital() public onlyPauserOrGovernorOrStrategist {
        capitalPaused = false;
        emit CapitalUnpaused();
    }

    /**
     * @dev Return the address of the pauser contract
     */
    function pauser() public view override returns (address) {
        return _pauser;
    }

    /**
     * @dev Execute the pause action
     */
    function _pause() internal override {
        pauseCapital();
        pauseRebase();
    }

    /**
     * @dev Execute the unpause action
     */
    function _unpause() internal override {
        unpauseCapital();
        unpauseRebase();
    }

    /**
     * @dev Returns true if the current user can pause the contract (in addition to the pauser)
     * Required by the pausable specification.
     */
    function _canPause() internal view override returns (bool) {
        return _isGovernorOrStrategist();
    }

    /**
     * @dev Returns true if the current user can unpause the contract (in addition to the pauser)
     * Required by the pausable specification.
     */
    function _canUnpause() internal view override returns (bool) {
        return isGovernor();
    }

    /***************************************
                    Utils
    ****************************************/

    /**
     * @dev Transfer token to governor. Intended for recovering tokens stuck in
     *      contract, i.e. mistaken sends.
     * @param _asset Address for the asset
     * @param _amount Amount of the asset to transfer
     */
    function transferToken(address _asset, uint256 _amount)
        external
        onlyGovernor
    {
        require(!assets[_asset].isSupported, "Only unsupported assets");
        IERC20(_asset).safeTransfer(governor(), _amount);
    }

    /**
     * @dev Checks if the current user is a governor or strategist
     * @return true if the user is a governor or strategist, false otherwise
     */
    function _isGovernorOrStrategist() private view returns(bool) 
    {
        return msg.sender == strategistAddr || isGovernor();
    }

    /***************************************
                    Pricing
    ****************************************/

    /**
     * @dev Returns the total price in 18 digit USD for a given asset.
     *      Never goes above 1, since that is how we price mints
     * @param asset address of the asset
     * @return uint256 USD price of 1 of the asset, in 18 decimal fixed
     */
    function priceUSDMint(address asset) external view returns (uint256) {
        uint256 price = IOracle(priceProvider).price(asset);
        if (price > 1e8) {
            price = 1e8;
        }
        // Price from Oracle is returned with 8 decimals so scale to 18
        return price.scaleBy(18, 8);
    }

    /**
     * @dev Returns the total price in 18 digit USD for a given asset.
     *      Never goes below 1, since that is how we price redeems
     * @param asset Address of the asset
     * @return uint256 USD price of 1 of the asset, in 18 decimal fixed
     */
    function priceUSDRedeem(address asset) external view returns (uint256) {
        uint256 price = IOracle(priceProvider).price(asset);
        if (price < 1e8) {
            price = 1e8;
        }
        // Price from Oracle is returned with 8 decimals so scale to 18
        return price.scaleBy(18, 8);
    }

    /***************************************
             Strategies Admin
    ****************************************/

    /**
     * @dev Withdraws all assets from the strategy and sends assets to the Vault.
     * @param _strategyAddr Strategy address.
     */
    function withdrawAllFromStrategy(address _strategyAddr)
        external
        onlyGovernorOrStrategist
    {
        require(
            strategies[_strategyAddr].isSupported,
            "Strategy is not supported"
        );
        IStrategy strategy = IStrategy(_strategyAddr);
        strategy.withdrawAll();
    }

    /**
     * @dev Withdraws all assets from all the strategies and sends assets to the Vault.
     */
    function withdrawAllFromStrategies() external onlyGovernorOrStrategist {
        for (uint256 i = 0; i < allStrategies.length; i++) {
            IStrategy strategy = IStrategy(allStrategies[i]);
            strategy.withdrawAll();
        }
    }
}
