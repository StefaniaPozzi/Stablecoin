//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {DEXStablecoin} from "./DEXStablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

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
        }
    }

    /**
     * @param _token wBTC or wETH
     */
    function depositCollateral(address _token, uint256 _amount) external needsMoreThanZero(_amount) nonReentrant {
        s_collateralDeposited[msg.sender][_token] += _amount;
        emit DEXSEngine_collateralAdded(msg.sender, _token, _amount);
    }

    function depositCollateralAndMint() external {}

    function mintDEXS() external {}

    function burnDEXS() external {}

    function liquidate() external {}

    function healthFactor() external {}
}
