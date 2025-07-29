// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test,console} from "forge-std/Test.sol";
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
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; 
    uint256 public constant STARTING_ERC20_Balance = 10 ether;

    function setUp() public {
        deployer = new DeployDSC(); // note: this is more of an integration than unit test.
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, ,) = config.activeNetworkConfig();

        // the only reason we i.e. the test contract can mint the ERC20 below is because its a mock contract! In real erc20 only owners can usually mint!
        ERC20Mock(weth).mint(USER, STARTING_ERC20_Balance);    
    }

    // Constructor Tests //
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLEngthDoesntMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(btcUsdPriceFeed);
        priceFeedAddresses.push(weth);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // Price Tests //

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18; // 15 eth tokens
        // 15e18 * 3000/ETH = 450000e18
        uint256 expectedUsd = 45000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether; // 100 *10e18 i.e. in solidity terms 100 of token amount. if 1 token mimicks 1 usd we have 100 usd 
        // he assumes 2000 usd / eth
        // how can we do that correctly? it keeps failing
        //uint256 ethUsdMarketPrice = 3713; // check later why it keeps failing
        uint256 expectedWeth = 0.05 ether; //(usdAmount /  ethUsdMarketPrice); // usd 100 of eth / eth/usd price (aka divide by market price of 1 eth in usd) 
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    // Deposit Collateral Tests //

    function testRevertsIfCollateralZero() public {
        // ?? get the logic on how to construct that test at all with the erc20 stuff etc! and how we need to do it with an address etc.
        vm.startPrank(USER); // we need to prank the user so it calls the appprove function on the ERC20Mock i.e. becomes the msg.sender of the next function
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL); // we approve the DSCEngine contract to call the transferFrom function within its depositCollateral function!

        // The below is saying: "I expect the next transaction to fail with THIS specific error code."
        // Foundry checks that when the transaction reverts, the revert data starts with the exact 4-byte selector of DSCEngine__NeedsMoreThanZero().
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector); // The EVM encodes the revert reason using the error selector // Error Selector: bytes4(keccak256("DSCEngine__NeedsMoreThanZero()")) 
        engine.depositCollateral(weth, 0);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("randomToken", "RAN", USER, AMOUNT_COLLATERAL); // the test user is the initial account
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressNotAllowed.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL); // user calls this function on erc20 token to approve engine to spend aka deposit amount collateral
        engine.depositCollateral(weth, AMOUNT_COLLATERAL); // also called by the USER
        vm.stopPrank(); // we need to stop pranking other wise any function that uses the modifier would call contract function as the USER
        _;
    }

    // figure out tomorrow what the issue is ...
    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        console.log("first expected coll", collateralValueInUsd);  

        uint256 expectedUsdcMinted = 0;
        uint256 expectedCollateralValueInUsd = engine.getAccountCollateralValueInUsd(USER);
        console.log("second expected coll", expectedCollateralValueInUsd);    
        // 🔍 DEBUG: What values are we actually getting?
        console.log("Total DSC minted:", totalDscMinted);
        console.log("Collateral value in USD:", collateralValueInUsd);
        console.log("AMOUNT_COLLATERAL:", AMOUNT_COLLATERAL);
        // Instructor's test (round-trip accuracy check)
        uint256 expectedDepositedAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    
        // Both check DSC minted is 0
        //assertEq(totalDscMinted, 0);
        //assertEq(expectedUsdcMinted, totalDscMinted);
        //assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }
}