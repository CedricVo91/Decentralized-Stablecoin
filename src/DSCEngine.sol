// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
* @title DSCEngine
* @author Cedric Vogt
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    
    // Errors
    error DSCEngine__NeedsMoreThanZero(); // always start with the contract name in custom errors
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenAddressNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__MintFailed();

    // State Variables
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // (means 50%) -> you can only use 50% of your collateral's value -> if you want to mint 100 DSC (i.e. $100 worth of DSC) you need 200 USD collateral as only half of that collateral is usable
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed that maps what tokens are allowed to add as collateral
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens; // to loop over mappings, we need an array -> used in getAccountCollateralValue() below

    // Events
    event CollteralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    // Modifiers
    modifier moreThanZero(uint256 amount) {
        if (amount == 0){
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token){
        if (s_priceFeeds[token] == address(0)) { // if the token address is not in our pricefeed i.e. it points to the zero address
            revert DSCEngine__TokenAddressNotAllowed();
            _;
        }
    }

    // constructor
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address decentralizedStableCoinAddress) {
        
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]); // to loop over mappings, we need an array -> used in getAccountCollateralValue() below
        }

        i_dsc = DecentralizedStableCoin(decentralizedStableCoinAddress); // we will use our DecentralizedStableCoin token contract a lot here, so we initialize it in the constructor.
        
    }

    // External Functions
    function depositCollateralAndMintDsc() external {}

    /**
    * @notice follows CEI
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) external moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        // without the transferFrom and just the s_collDeposited mapping update, the user still owns the collateralToken, so he needs to update the actual ERC20 token contract's balances aka actually taking custody
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral); // actually transfering the collateral from its token erc20 contract
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollteralDeposited(msg.sender, tokenCollateralAddress, amountCollateral); // when we modify state we emit an event
        
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    // 1. Check if the collateral value:
    // - DSC amount, PriceFeed

    /**
    * @notice follows CEI
    * @param amountDscToMint the amount of decentralized stablecoin to mint
    * @notice they must have more collateral than the minimum threshold
    */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        // if they minted too much (e.g. $150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender); // ?? does this undo the above updated mapping of s_dscMinted?
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}


    // Private and Internal View Functions
    /**
    * Returns how closte to liquidation a user is
    * If a user goes below 1, then they can get liquidated
    */

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
        return (totalDscMinted, collateralValueInUsd);
    }


    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        // collateralAdjustedForThreshol -> the collateral in usd  that we can mint 1 to 1 for DSC: e.g. if its 100 we can mint 100 dsc or less (depending on how overcollateralized we want to be)
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION); // ?? research on why we can have a normal divide here despite the decimals and solidity saying decimals does not work ..also how does the overcollaterilzation of 200% work e.g. // 1000 eth * 50 / 100 = 500 // ???
        
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; // ?? do we need the precision as the eth in usd chainlink price feed does not have the same amount of decimals as the dsc token amount?

        // other example of health factor:
        // $1000 worth of ETH and has 100 DSC -> collateralAdjustedForThreshold = (1000 * 50 / 100) = 500, collaterAdjustedThreshold / 100 DSC -> healthfactor = 5 > 1 
    }

    function _revertIfHealthFactorIsBroken(address user) internal view { // underscore as its an internal function
        // 1. Check health facotr (do they have enough collateral?)
        // 2. Revert if they don't 
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine__BreaksHealthFactor();
        }
    }

    // Public & External View Functions
    function getAccountCollateralValueInUsd(address user) public view returns(uint256 totalCollateralValueinUsd){
        // loop through each collateral token, get the amount they have deposited and map each to pricefeeds
        for (uint256 i = 0; i<s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueinUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueinUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // ?? check this afternoon why we do that!
    }



}