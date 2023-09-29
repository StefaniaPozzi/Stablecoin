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

    uint256 private constant PRICE_MISSING_DECIMALS_TO_BE_ROUNDED_IN_WEI = 1e10;
    uint256 private constant ETH_IN_WEI_PRECISION = 1e18;
    uint256 private constant FEED_PRECISION = 1e8;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    address[] s_collateralTokenSupported;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 DEXSMinted) private s_dexsminted;

    DEXStablecoin private immutable i_dexstablecoin;

    event DEXSEngine_collateralAdded(address indexed user, address indexed token, uint256 indexed amount);

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
    function depositCollateral(address _token, uint256 _amount) external needsMoreThanZero(_amount) nonReentrant {
        s_collateralDeposited[msg.sender][_token] += _amount;
        emit DEXSEngine_collateralAdded(msg.sender, _token, _amount);
        (bool success) = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert DEXSEngine_TransferFailed();
        }
    }

    function depositCollateralAndMint() external {}

    /**
     * @notice we need more collateral than minimum threshold
     */
    function mintDEXS(uint256 _amount) external needsMoreThanZero(_amount) nonReentrant {
        s_dexsminted[msg.sender] += _amount;
        _checkHealthFactor(msg.sender);
        bool minted = i_dexstablecoin.mint(msg.sender, _amount);
        if (!minted) {
            revert DEXSEngine_MintFailed();
        }
    }

    function burnDEXS() external {}

    function liquidate() external {}

    /**
     * @notice If health factor < 1 => the user is liquidated
     * Overcollateralisation of x2
     */
    function healthFactor(address user) public view returns (uint256) {
        (uint256 dexsMintedInWei, uint256 collateralValue) = _accountInfo(user);
        uint256 reducedCollateralWithLiquidationThreshod = collateralValue / 2;
        return (reducedCollateralWithLiquidationThreshod * ETH_IN_WEI_PRECISION / dexsMintedInWei);
    }

    function _checkHealthFactor(address user) internal view {
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
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 priceRoundedInWei = uint256(price) * PRICE_MISSING_DECIMALS_TO_BE_ROUNDED_IN_WEI;
        return ((priceRoundedInWei * usdAmountInWei) / ETH_IN_WEI_PRECISION);
    }

    function getPriceFeed(address token) public returns (address) {
        return s_priceFeeds[token];
    }
}
