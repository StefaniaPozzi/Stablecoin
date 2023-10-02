//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {DEXStablecoin} from "./DEXStablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";

/**
 * @title DEXSEngine
 * @author Stefania Pozzi
 *
 * This contract keeps the value of 1 DEXS == 1 $
 * @notice It handles all the logic for
 * 1. minting and burning tokens
 * 2. deposit and withdraw collateral
 * @notice system similar to MakerDAO (overcollatereralisation)
 * This protocol always has to be overcollateralised
 * -> it always has more collateral than DEXS
 */
contract DEXSEngine is ReentrancyGuard {
    error DEXSEngine_NeedsMoreThanZero();
    error DEXSEngine_TokensPriceFeedArrayMismatched();
    error DEXSEngine_TokenNotAllowed();
    error DEXSEngine_TransferFailed();
    error DEXSEngine_HealthFactorIsBelowThreshold();
    error DEXSEngine_MintFailed();
    error DEXSEnging_CannotLiquidate();
    error DEXSEngine_HealthFactorNotImproved();
    error DEXSEngine_LiquidatorHealthFactorNegative(); //?

    uint256 private constant PRICE_MISSING_DECIMALS_DOLLAR_TO_WEI = 1e10;
    uint256 private constant ETH_IN_WEI_PRECISION = 1e18;
    uint256 private constant FEED_PRECISION = 1e8;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_PERCENTAGE = 10;
    uint256 private constant LIQUIDATION_BASIS = 100;

    address[] s_collateralTokenSupported;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dexminted) private s_dexsminted;

    DEXStablecoin private immutable i_dexstablecoin;

    event DEXSEngine_collateralAdded(address indexed user, address indexed token, uint256 indexed amount);
    event DEXSEngine_CollateralRedeemed(
        address indexed from, address indexed to, address indexed token, uint256 amount
    );

    modifier needsMoreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DEXSEngine_NeedsMoreThanZero();
        }
        _;
    }

    modifier isCollateralTokenAllowed(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DEXSEngine_TokenNotAllowed();
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddressess, address _dexsaddress) {
        if (tokenAddresses.length != priceFeedAddressess.length) {
            revert DEXSEngine_TokensPriceFeedArrayMismatched();
        }
        i_dexstablecoin = DEXStablecoin(_dexsaddress);
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddressess[i];
            s_collateralTokenSupported.push(tokenAddresses[i]);
        }
    }

    /**
     * @param _token wBTC or wETH
     */
    function depositCollateral(address _token, uint256 _amount) public needsMoreThanZero(_amount) nonReentrant {
        s_collateralDeposited[msg.sender][_token] += _amount;
        emit DEXSEngine_collateralAdded(msg.sender, _token, _amount);
        (bool success) = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert DEXSEngine_TransferFailed();
        }
    }

    function depositCollateralAndMint(address _token, uint256 _tokenAmount, uint256 _dexsAmount) external {
        depositCollateral(_token, _tokenAmount);
        mintDEXS(_dexsAmount);
    }

    function redeemCollateralForDEXS(address token, uint256 amount, uint256 dexsToBurn) external {
        burnDEXS(amount);
        redeemCollateral(token, amount);
    }

    /**
     * Health factor must remain > 1 after the collateral is redeemed
     * @notice solidity compiler throws an error if the user is trying to redeem more than he has deposited
     * @notice it's possible to check the health factor before sending the collateral but that's gas inefficient
     */

    function redeemCollateral(address token, uint256 amount) public needsMoreThanZero(amount) nonReentrant {
        _redeemCollateralFrom(token, amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _redeemCollateralFrom(address token, uint256 amount, address from, address to)
        private
        needsMoreThanZero(amount)
        nonReentrant
    {
        s_collateralDeposited[from][token] -= amount;
        emit DEXSEngine_CollateralRedeemed(from, to, token, amount);
        bool success = IERC20(token).transfer(to, amount);
        if (!success) {
            revert DEXSEngine_TransferFailed();
        }
    }

    /**
     * Burns an amount of DEXS on behalf of an address (target).
     * Performed by a liquidator contract (from).
     *
     * @param amount the amount of DEXS to be burned
     * @param target the address of whom are we burning from, whose debt is paying down
     * @param from the liquidator who pays the debt for the target (DEXS) and get back the target collateral (ETH|BTC)
     *
     * @dev do not call this directly: it does not check the health factor
     */
    function _burnDEXSFrom(uint256 amount, address from, address target)
        private
        needsMoreThanZero(amount)
        nonReentrant
    {
        s_dexsminted[target] -= amount;
        //the liquidator must have these tokens -> no checks??
        bool success = i_dexstablecoin.transferFrom(from, address(this), amount);
        if (!success) {
            revert DEXSEngine_TransferFailed();
        }
        i_dexstablecoin.burn(amount);
    }

    /**
     * Minting is possible only if the caller of this function has enough collateral
     * @param amount amount of DEXS the callers wants to mint (e.g. 7 DEXS)
     *
     * @dev we add the amount to s_dexminted anyway because
     * we use it to calculate the Health Factor in the method _revertIfHealthFactorIsBroken.
     * If this function reverts, s_dexsminted will go back to its original state.
     */
    function mintDEXS(uint256 amount) public needsMoreThanZero(amount) nonReentrant {
        s_dexsminted[msg.sender] += amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dexstablecoin.mint(msg.sender, amount);
        if (!minted) {
            revert DEXSEngine_MintFailed();
        }
    }

    function burnDEXS(uint256 amount) public needsMoreThanZero(amount) {
        _burnDEXSFrom(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * Liquidates some user's debt
     *
     * @notice it's possible to partially liquidate a user
     * @notice a bonus (10% of the debt) is granted to the caller of this function
     *
     * @dev When to liquidate
     * 1. if insolvent users' health factor is broken
     * 2. if liquidator's health factor is broken
     * 3. if at the end of the liquidation, the user is not insolvent anymore
     * Otherwise we revert all txs
     *
     * Redeem collateral
     * 1. estimate how much ETH|BTC the debt (DEXS) was worth -> actual debt worth (actualDebtWorthToken)
     * 2. bonus: send 10% of the actual debt worth to the caller of this function
     * 3. transfer the debt + bonus to the liquidator
     *
     * Burn DEXS
     * 3. the liquidator burns !its own! DEXS (in order to cover the target's DEXS debt)
     * And he gets the redeemedCollateralWithBonus (ETH or BTC)
     *
     * @param token the token address of the collateral to remove from the user
     * @param user the insolvent user
     * @param debtUSDWEI the amount of DEXS to burn to cover user's debt
     *
     */
    function liquidate(address token, address user, uint256 debtUSDWEI)
        external
        needsMoreThanZero(debtUSDWEI)
        nonReentrant
    {
        uint256 userStartingHealthFactor = healthFactor(user);
        if (userStartingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DEXSEnging_CannotLiquidate();
        }

        uint256 actualDebtWorthToken = getTokenAmountFromUsd(token, debtUSDWEI);
        uint256 bonus = actualDebtWorthToken * LIQUIDATION_PERCENTAGE / LIQUIDATION_BASIS;
        uint256 redeemedCollateralWithBonus = actualDebtWorthToken + bonus;

        _redeemCollateralFrom(token, redeemedCollateralWithBonus, user, msg.sender);
        _burnDEXSFrom(debtUSDWEI, msg.sender, user);

        uint256 userEndingHealthFactor = healthFactor(user);
        if (userEndingHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DEXSEngine_HealthFactorNotImproved();
        }
    }

    /**
     * @notice It calculates the Health Factor for a user starting from his account information.
     * The liquidation threshold is set to double its collateral.
     * This mean that TODO
     * @notice Overcollateralisation of x2
     */
    function healthFactor(address user) public view returns (uint256) {
        (uint256 dexsOwned, uint256 collateralUSDWEI) = _accountInfo(user);
        uint256 reducedCollateralWithLiquidationThreshod = collateralUSDWEI / 2;
        return (reducedCollateralWithLiquidationThreshod * ETH_IN_WEI_PRECISION / dexsOwned);
    }

    /**
     * Gives user basic information:
     * @return dexsMinted DEXS amount that belongs to the user 
     * @return collateralUSDWEI USD value in WEI that corresponds to the deposited
     * collateral (originally in ETH|BTC)
    */
    function _accountInfo(address user) private view returns (uint256 dexsMinted, uint256 collateralUSDWEI) {
        dexsMinted = s_dexsminted[user];
        collateralUSDWEI = getCollateralUSDWEI(user);
    }

    /**
     * Reverts if user's Health Factor goes below the MIN_HEALTH_FACTOR
     * @dev it calls the main healthFactor function
    */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DEXSEngine_HealthFactorIsBelowThreshold();
        }
    }

    function getCollateralUSDWEI(address user) public view returns (uint256) {
        uint256 collateralValue;
        for (uint256 i = 0; i < s_collateralTokenSupported.length; i++) {
            address token = s_collateralTokenSupported[i];
            uint256 collateral = s_collateralDeposited[user][token];
            collateralValue = convertToUsdc(token, collateral);
        }
    }

    function convertToUsdc(address token, uint256 usdAmountInWei) public view returns (uint256) {
        int256 price = getLatestRoundData(s_priceFeeds[token]);
        uint256 priceRoundedInWei = uint256(price) * PRICE_MISSING_DECIMALS_DOLLAR_TO_WEI;
        return ((priceRoundedInWei * usdAmountInWei) / ETH_IN_WEI_PRECISION);
    }

    /**
     * Converts from USD with WEI precision to ETH|BTC in WEI precision
     *
     * @dev Procedure:
     * 1. uses the method getLatestRoundData to get the latest price
     * of the collateral (ETH|BTC) -> precision is 8 decimals
     * 2. it converts it to WEI precision (18 decimals) - misses 1e10
     * @dev The price feed returns the value of 1ETH = e.g. 2000$
     * -> 2000$ = 1ETH
     * -> 1$ = 1/2000 ETH
     * -> 50$ = 50/2000 ETH
     *
     * @return amountTokenWEI must have 1e18 precision (WEI)
     */
    function getTokenAmountFromUsd(address token, uint256 amountUSDWEI) public view returns (uint256 amountTokenWEI) {
        int256 price = getLatestRoundData(s_priceFeeds[token]);
        uint256 priceUSDWEI = uint256(price) * PRICE_MISSING_DECIMALS_DOLLAR_TO_WEI;
        amountTokenWEI = (amountUSDWEI / priceUSDWEI) * 1e18;
    }

    /**
     * Uses the AggregatorV3Interface to get the latest price for the collateral
     * @param priceFeedAddress the network pegged price feed for the specific token
     * @return price dollar with 8 decimals precision
     */
    function getLatestRoundData(address priceFeedAddress) public view returns (int256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return price;
    }

    function getPriceFeed(address token) public returns (address) {
        return s_priceFeeds[token];
    }
}
