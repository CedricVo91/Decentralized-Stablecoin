/*
// SPDX-License-Identifier: MIT

// Have our invariants

// What are our invariants?

// 1. The total supply of DSC should be less than the total value of collateral
// 2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.19;


import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,,weth,wbtc,) = config.activeNetworkConfig();
        // Added these debug lines:
        console.log("DSC address:", address(dsc));
        console.log("Engine address:", address(engine));
        console.log("WETH address:", weth);
        console.log("WBTC address:", wbtc);
        //invariant_protocolMustHaveMoreValueThanTotalSupply();
        // all the public and external functions of our engine contract below get tested: random functions get called in sequences and after each sequence it checks my invariant: 
        targetContract(address(engine)); // Foundry introspects the DSCEngine bytecode, finds all public/external functions, and adds them to its "callable function pool" for fuzzing
    }
    // the invariants: all functions that start with invariant_ -> get called after each sequence of random function calls of the public/external functions of engine i.e. the target contract
    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value: ", wethValue);
        console.log("wbtc value: ", wbtcValue);
        console.log("total supply", totalSupply);

        assert(wethValue + wbtcValue >= totalSupply); // the actual invariant checks that happen at the end of each sequence
    }

    //function invariant_alwaysTrue() public pure {
    //    assert(true);
    //}
}
*/