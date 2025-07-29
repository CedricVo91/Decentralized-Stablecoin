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
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    // State Variables
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // (means 50%) -> you can only use 50% of your collateral's value -> if you want to mint 100 DSC (i.e. $100 worth of DSC) you need 200 USD collateral as only half of that collateral is usable
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATOR_BONUS = 10; // a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed that maps what tokens are allowed to add as collateral
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens; // to loop over mappings, we need an array -> used in getAccountCollateralValue() below

    // Events
    event CollteralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom,address indexed redeemedTo,  address indexed token, uint256 amount);

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
        }
        _;
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

    /**
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice This function will deposit your collateral and mint tokens
    */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
    * @notice follows CEI
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        // without the transferFrom and just the s_collDeposited mapping update, the user still owns the collateralToken, so he needs to update the actual ERC20 token contract's balances aka actually taking custody
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral); // actually transfering the collateral from its token erc20 contract
        // note: we cant have an approve function within the DSCEngine, as the user (msg.sender) needs to approve the DSC to spend token on his behalf, not otherwise for obvious reasons (security, logic)
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollteralDeposited(msg.sender, tokenCollateralAddress, amountCollateral); // when we modify state we emit an event   
    }

    /**
    * @param tokenCollateralAddress The collateral address to redeem
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to burn
    * Note this function burns DSC and redeems underlying collateral in one transaction
    */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    // In order to redeem collateral: 
    // 1. health factor must be over 1 AFTER collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender); // from and to are the same address, nice design
        _revertIfHealthFactorIsBroken(msg.sender); // problem: without a burn dsc step before, we would break our health factor by requesting all the collateral back (but still holding the dsc) -> we do that in the combination function
    }

    /**
    * @notice follows CEI
    * @param amountDscToMint the amount of decentralized stablecoin to mint
    * @notice they must have more collateral than the minimum threshold
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        // if they minted too much (e.g. $150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint); // the mint function of the dsc is called by the engine aka the owner, not by the caller of mintDsc function!
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount)  {
        s_dscMinted[msg.sender] -= amount; // -> this means that if just any external user without an amount on the mapping would run an underflow error by design and it would be reverted
        // the below only works in testing if the external user (msg.sender) approves the dsc engine to transfer his token amount to the engine contract
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount); // we have to update the dsc ledger so that the user (msg.sender) does not have the dsc anymore, otherwise we would just burn random dsc, decreasing the supply
        if (!success){
            revert DSCEngine.DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount); // dscengine burns - as the owner of i_dsc - the amount above 
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this will ever hit as we can burn DSC as much as we want
    }

    /**
    * @param collateral The erc20 collateral address to liquidate from the user
    * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC you want to burn to improve the users health factor
    * @notice You can partially liquidate a user. 
    * @notice You will get a liquidation bonus for taken the users funds.
    * @notice This function working assume the protocol will be roughly 200% overcollateralized in order for this to work.
    * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldnt be able to incentivize the liquidators.
    */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        // CEI: checks, effects, interactions

        // Check health factor of user we want to liquidate
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // we want to burn the dsc of the msg.sender 
        // remove user collateral
        // return collateral to msg.sender
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover); // how much of collateral have we covered with our burn dsc
        // And give them a 10% bonus
        // So we are giving the liquidator $110 
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATOR_BONUS)/ LIQUIDATION_PRECISION; 
        uint256 totalCollateralToRedeemToLiquidator = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeemToLiquidator, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender); // so here we need an approval for the dsc by the liquidator in a testing scenario as we transfer dsc to burn from the liquidator to the engine (see the burn function logic)
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    // Private and Internal View Functions
    /**
    * @dev Low-level internal function, do not call this _burnDsc function unless the function calling it is checking for health factors being broken (e.g. in liquidator function!)
    * @param onBehalfOf This the undercollateralized account whose dsc gets burnt
    * @param dscFrom This is the address of the liquidator who sends dsc to the contract, before dsc engine burns it
    */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn); // we have to update the dsc ledger so that the user (msg.sender) does not have the dsc anymore, otherwise we would just burn random dsc, decreasing the supply, right?
        if (!success){
            revert DSCEngine.DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }
    
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        //bool success = IERC20(tokenCollateralAddress).transferFrom(address(this), msg.sender, amountCollateral);
        // no approval needed below as the dsc engine owns its own token and transfers these
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral); // as the DSCEngine is the contract, it can directly use the transfer function, no need for transferfrom
        if (!success){
            revert DSCEngine__TransferFailed();
        }
    } 

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
        if (totalDscMinted == 0) return type(uint256).max; // to prevent the division by zero when there is no dsc debt, my health factor should be infinite, and not cause a division by zero. I discovered this during fuzztesting the redeem collateral function. 
        // collateralAdjustedForThreshol -> the collateral in usd  that we can mint 1 to 1 for DSC: e.g. if its 100 we can mint 100 dsc or less (depending on how overcollateralized we want to be)
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION); // in solidity decimals like 0.5 (i.e. 50% are not allowed) -> we do it by 50 (threshold) divided 100(liq_precision)
        // careful: ERC20 Tokens - like totalDscMinted - have 18 decimals!
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; // as both totalDscMinted and collateralAdjustedForT have 10e18 endings i.e. 5000 usd in solidity is 5000*10^18, we need to divide by PRECISION (10^18)
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
    function getCollateralBalanceOfUser(address user, address collateral) external view returns (uint256){
        return s_collateralDeposited[user][collateral];
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        // price of ETH (token)
        // $/ETH ??
        //2000 dsc_usd gets burned, so we get the how many eth tokens? 1 eth/ in usd price -> 1/1ethusdpricefeed * 2000 dsc = eth amount
        (,int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18*1e18) / ($2000e8*1e10) -> final has always 18 decimals
        return  (usdAmountInWei * PRECISION)/ (uint256(price)* ADDITIONAL_FEED_PRECISION); // ? why a uint256 typecasting? 
    }

    function getAccountCollateralValueInUsd(address user) public view returns(uint256 totalCollateralValueinUsd){
        // loop through each collateral token, get the amount they have deposited and map each to pricefeeds
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueinUsd += getUsdValue(token, amount); // collateral value has 18 decimals per getUSDValue (see function below)
        }
        return totalCollateralValueinUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData(); // price has 8 decimals per chainlink
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // amount has 18 decimals (1 ETH has 18 decimals per definition) -> once amount and price both have 18 decimals meaning both are of same magnitude, we can divide one of them by 10e18 (precision) and have our final value with 18 decimals 
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getAccountInformation(address user) external view returns (uint256, uint256){
        return _getAccountInformation(user);
    }


}