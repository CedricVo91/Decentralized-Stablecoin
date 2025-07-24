// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19; 

import {Script} from "forge-std/Script.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;
    
    // I need the contractor entries of DSCEngine, plus DSCEngine needs to be the owner of the dsc coin contract to mint and other stuff
    function run() external returns (DecentralizedStableCoin,DSCEngine, HelperConfig) { // the run function always needs to return at least a contract!Can never use it without a returns
        HelperConfig config = new HelperConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc,uint256 deployerKey) = config.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey); // All transactions now come from deployerKey account (anvil or sepolia account associated with the PK)
        DecentralizedStableCoin dsc = new DecentralizedStableCoin(vm.addr(deployerKey)); // initial owner of the stable coin is the account associated with the key now
        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc)); // this needs a bunch of token addresses -> create helper config
        // we transferownership from us, the deployer in vm.startbroadcast() to the engine account!
        dsc.transferOwnership(address(engine)); // as part of the vm.startBroadcast(), the account of the deployer key calls the dsc -> dsc is ownable and transferownership has onlyOwner modifier -> only the owner (which we are of dsc) can transferOwnership!
        vm.stopBroadcast();
        return (dsc, engine, config);
    }
}