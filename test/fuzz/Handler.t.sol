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

    // we initialize the contracts we want to call from in the Handler's constructor
    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        // collateralTokens is temporary -> just for initiaization -> use memory 
        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]); // typecasting ERC20Mock only works on mock contracts, not real testnet like sepolia.    
        wbtc = ERC20Mock(collateralTokens[1]);    
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

        // console.log("Handler address:", address(this));
        // console.log("Handler balance before:", collateral.balanceOf(address(this)));
        // console.log("Handler allowance:", collateral.allowance(address(this), address(engine)));
        // console.log("Trying to deposit:", amountCollateral);
    }

    // redeem collateral <- call this when I have collateral
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        console.log("max to redeem", maxCollateralToRedeem);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        console.log("final amountCollateral that gets redeemed", amountCollateral);
        if (amountCollateral == 0) {
            return;
        }
        vm.prank(msg.sender); // had to add this, but in the tutorial it worked without it.
        engine.redeemCollateral(address(collateral), amountCollateral);

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

