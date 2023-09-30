//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {DEXStablecoin} from "./DEXStablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DEXSEngine
 * @author Stefania Pozzi
 *
 * This contract keeps the value of 1 DEXS == 1 $
 * @notice It handles all the logic for
 * 1. minting and burning tokens
 * 2. deposit and withdraw collateral
 * @notice system similar to MakerDAO -> overcollateralised
 */
contract DEXSEngine is ReentrancyGuard {
    error DEXSEngine_NeedsMoreThanZero();
    error DEXSEngine_TokensPriceFeedArrayMismatched();
    error DEXSEngine_TokenNotAllowed();
    error DEXSEngine_TransferFailed();
    error DEXSEngine_HealthFactorIsBelowThreshold();
    error DEXSEngine_MintFailed();
    error DEXSEnging_CannotLiquidate();

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
        redeemCollateralFrom(token, amount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateralFrom(address token, uint256 amount, address from, address to)
        public
        needsMoreThanZero(amount)
        nonReentrant
    {
        s_collateralDeposited[from][token] -= amount;
        emit DEXSEngine_CollateralRedeemed(from, to, token, amount);
        bool success = IERC20(token).transfer(to, amount);
        if (!success) {
            revert DEXSEngine_TransferFailed();
        }
        revertIfHealthFactorIsBroken(to);
    }

    /**
     * @notice we need more collateral than minimum threshold
     */
    function mintDEXS(uint256 _amount) public needsMoreThanZero(_amount) nonReentrant {
        s_dexsminted[msg.sender] += _amount;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dexstablecoin.mint(msg.sender, _amount);
        if (!minted) {
            revert DEXSEngine_MintFailed();
        }
    }

    function burnDEXS(uint256 amount) public needsMoreThanZero(amount) {
        s_dexsminted[msg.sender] -= amount;
        bool success = i_dexstablecoin.transferFrom(address(msg.sender), address(this), amount);
        if (!success) {
            revert DEXSEngine_TransferFailed();
        }
        i_dexstablecoin.burn(amount);
    }

    /**
     * @notice the caller of this function will perform
     * redeemCollateralForDEXS (burn+redeem) for a debt-user if his health_factor < 1
     * @notice it's possible to partially liquidate a user -> TODO
     * @notice a bonus is granted to the caller of this function if he performs this function
     *
     * @dev check if the health factor is eligible, otherwise revert
     * @dev the engine has to get rid of the debt-user tokens:
     * 1. burn his DEXS debt
     * 2. estimate how much ETH|BTC those DEXS were worth -> actual debt worth (actualDebtWorthToken)
     * 3. bonus: send 10% of the actual debt worth to the caller of this function
     *
     * @param token the token address of the collateral to remove from the user
     * @param user the user that whom hf < 1
     * @param debtUSDWEI the amount of DEXS to burn to put the user's health factor back to > 1
     *
     */
    function liquidate(address token, address user, uint256 debtUSDWEI)
        external
        needsMoreThanZero(debtUSDWEI)
        nonReentrant
    {
        uint256 startingUserHF = healthFactor(user);
        if (startingUserHF >= MIN_HEALTH_FACTOR) {
            revert DEXSEnging_CannotLiquidate();
        }

        uint256 actualDebtWorthToken = getTokenAmountFromUsd(token, debtUSDWEI);
        uint256 bonus = actualDebtWorthToken * LIQUIDATION_PERCENTAGE / LIQUIDATION_BASIS;
        uint256 redeemedCollateral = actualDebtWorthToken + bonus;

        redeemCollateralFrom(token, redeemedCollateral, user, msg.sender);
    }

    /**
     * @notice If health factor < 1 => the user is liquidated
     * @notice Overcollateralisation of x2
     */
    function healthFactor(address user) public view returns (uint256) {
        (uint256 dexsMintedInWei, uint256 collateralValue) = _accountInfo(user);
        uint256 reducedCollateralWithLiquidationThreshod = collateralValue / 2;
        return (reducedCollateralWithLiquidationThreshod * ETH_IN_WEI_PRECISION / dexsMintedInWei);
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DEXSEngine_HealthFactorIsBelowThreshold();
        }
    }

    function _accountInfo(address user) private view returns (uint256 dexsMinted, uint256 collateralValue) {
        dexsMinted = s_dexsminted[user];
        collateralValue = getCollateralValue(user);
    }

    function getCollateralValue(address user) public view returns (uint256) {
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
     * @dev The price feed returns the value of 1ETH = e.g. 2000$
     * -> 2000$ = 1ETH
     * -> 1$ = 1/2000 ETH
     * -> 50$ = 50/2000 ETH
     *
     * @dev priceFeed must be rounded to 1e18 from 1e8 -> misses 1e10
     * @dev result must be 1e18
     * @return amountTokenWEI
     */
    function getTokenAmountFromUsd(address token, uint256 amountUSDWEI) public view returns (uint256 amountTokenWEI) {
        int256 price = getLatestRoundData(s_priceFeeds[token]);
        uint256 priceUSDWEI = uint256(price) * PRICE_MISSING_DECIMALS_DOLLAR_TO_WEI;
        amountTokenWEI = (amountUSDWEI / priceUSDWEI) * 1e18;
    }

    function getPriceFeed(address token) public returns (address) {
        return s_priceFeeds[token];
    }

    /**
     * @param priceFeedAddress the network pegged price feed for the specific token
     * @return price dollar with 8 decimals precision
     */
    function getLatestRoundData(address priceFeedAddress) public view returns (int256 price) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
    }
}
