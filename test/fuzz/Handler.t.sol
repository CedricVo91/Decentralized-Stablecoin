// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth; // use mocks to be able to mint from any pranked user (see below in depositCollateral)
    ERC20Mock wbtc;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    address[] public usersWhoDepositedCollateral;
    address[] public userWhoDepositedAndMinted;

    // we initialize the contracts we want to call from in the Handler's constructor
    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        // collateralTokens is temporary -> just for initiaization -> use memory 
        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]); // typecasting ERC20Mock only works on mock contracts, not real testnet like sepolia.    
        wbtc = ERC20Mock(collateralTokens[1]);    
        }

    // we want to mint our dsc, not the collateral here
    // as per deployer script, we transfer ownership of the dsc to the dsc engine! so the engine can mint 
    function mintDsc(uint256 amountDscToMint, uint256 addressSeed) public {
        // we need to enter our fuzztester (msg.sender) as the one calling the engine's mintDsc so that it 
        amountDscToMint = bound(amountDscToMint, 1, MAX_DEPOSIT_SIZE); // need to account for modifier Not Zero
        if (usersWhoDepositedCollateral.length == 0) {
            return;
        } 
        address sender = usersWhoDepositedCollateral[addressSeed % usersWhoDepositedCollateral.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender); // gets called by the handler for the caller of the handler (msg.sender) account information
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted); // we only have half of our collateral value in usd available for minting, so we deduct the totaldsc from it to know what we have left (here dsc is a stablecoin and already in the same currency i.e. usd as its pegged to it)
        // maxDscToMint is negative when collateral value drops below the total dscminted AND user hasnt been liquidated yet!
        if (maxDscToMint < 0) {
            console.log("we cant mint anymore DSC and User will be liquidated soon");
            return;
        } 

        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint)); // typecast: the bound function returns uint256 type and requires uint256 input parameters
        if (amountDscToMint == 0) { // that happens when maxDscToMint is zero and that also why the bound needs to be [0,0], to avoid [1,0]
            console.log("we cant mint anymore DSC as we minted the maximum of dsc given our current collateral");
            return;
        }
        vm.startPrank(sender);
        engine.mintDsc(amountDscToMint); // as our engine call the dsc.mint function inside the engine's mintDsc, the ownership is correct and has been accounted for
        vm.stopPrank(); 
        //delete usersWhoDepositedCollateral[addressSeed % usersWhoDepositedCollateral.length]; // add this to not allow someone who deposited 
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // engine.depositCollateral(collateral, amountCollateral);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral,1,MAX_DEPOSIT_SIZE);
        
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral); // thats why we use mocks: to be able to call the mint collateral from any user (i.e. any msg.sender)
        collateral.approve(address(engine), amountCollateral); // here this will be called by the msg.sender using our prank, however, the erc20 (aka collateral).transferfrom will be called inside the depositcollateral and hence that function is called by the engine (as the depositcollateral is a function of engine) and engine then needs approval to spend our users (msg.sender) Erc20 tokens 
        engine.depositCollateral(address(collateral), amountCollateral); // remember: even though the depostCollateral is called by the msg.sender, the transferfrom is called by the engine contract, NOT the msg.sender
        vm.stopPrank();
        usersWhoDepositedCollateral.push(msg.sender);
    }

    // redeem collateral <- call this when I have collateral
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral, uint256 addressSeed) public {
        // Select a user who actually has collateral to check full flow -> deposit, mint, redeem
        if (usersWhoDepositedCollateral.length == 0) {
        return;
        }
        address sender = usersWhoDepositedCollateral[addressSeed % usersWhoDepositedCollateral.length];
        
        //onsole.log("this account called redeem collateral", msg.sender);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(sender, address(collateral));
        
        //console.log("max to redeem", maxCollateralToRedeem);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return; // important: as the fuzzer calls randomly sometimes redeemCollateral first, then it needs to check if there has been any depost, if not, then just return and our test won't fail when it calls redeem before deposit randomly.
        }

        // I need another safety check in the handler, to avoid the situation where repeated minting followed by a redeem collateral would result in a healthFactor broken situation
        // Get projected health factor: healthfactor(totalDSCMinted, collateralvalueInUSD-USD(amountCollateral))
        // need to get his current collateral value before redeeming
        // subtract the usd value of the amountcollateral from this function
        // calculate healthfactor

        // issue: our function only take in user address -> so need to somehow modify the collateral array so that it is in memory
        (uint256 totalDscMinted, uint256 preRedeemCollateralValueInUsd) = engine.getAccountInformation(sender); // we need to get the dsc minted before redeeming
        uint256 projectedCollateralBalanceOfUserAfterRedeemingInUsd = preRedeemCollateralValueInUsd - engine.getUsdValue(address(collateral), amountCollateral); // we subtract the amountCollateral from above that we want to redeem
        // calulate the newHealthFactor if the redeem would happen
        uint256 projectedHealthFactor = engine.getHealthFactorForHandlerAdjustment(totalDscMinted, projectedCollateralBalanceOfUserAfterRedeemingInUsd);
        console.log("user projected health factor if collateral gets redeemed", projectedHealthFactor / 1e18);
        if (projectedHealthFactor < engine.getMinHealthFactor()) {
            console.log("health factor would be broken");
            return;
        }

        vm.prank(sender); // The msg.sender is the same as the msg.sender of the deposit function (the fuzz tester)
        // otherwise - without the pranking - the handler i.e. the contract of the function redeemCollateral would call the engine.redeemCollateral
        engine.redeemCollateral(address(collateral), amountCollateral);
        console.log("amount of collateral successfully redeemed", amountCollateral);
    }

    // Helper Functions
    // private view: so we dont call it from our invariants.t.sol file when we fuzztest the public/external functions of Handler.t.sol
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
        return wbtc;}
    }
}

