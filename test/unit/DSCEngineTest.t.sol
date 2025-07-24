// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; 
    uint256 public constant STARTING_ERC20_Balance = 10 ether;

    function setUp() public {
        deployer = new DeployDSC(); // ?? this set up is already kind of an integration test, right? ask claude
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed,, weth, , ) = config.activeNetworkConfig();

        // the only reason we i.e. the test contract can mint the ERC20 below is because its a mock contract! In real erc20 only owners can usually mint!
        ERC20Mock(weth).mint(USER, STARTING_ERC20_Balance);
    
    }

    // Price Tests

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18; // 15 eth tokens
        // 15e18 * 3000/ETH = 450000e18
        uint256 expectedUsd = 45000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    // Deposit Collateral Tests

    function testRevertsIfCollateralZero() public {
        // ?? get the logic on how to construct that test at all with the erc20 stuff etc! and how we need to do it with an address etc.
        vm.startPrank(USER); // we need to prank the user so it calls the appprove function on the ERC20Mock i.e. becomes the msg.sender of the next function
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL); // we approve the DSCEngine contract to call the transferFrom function within its depositCollateral function!

        // The below is saying: "I expect the next transaction to fail with THIS specific error code."
        // Foundry checks that when the transaction reverts, the revert data starts with the exact 4-byte selector of DSCEngine__NeedsMoreThanZero().
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector); // The EVM encodes the revert reason using the error selector // Error Selector: bytes4(keccak256("DSCEngine__NeedsMoreThanZero()")) 
        engine.depositCollateral(weth, 0);
    }


}