// SPDX-License-Identifier: MIT

// Have our invariants aka properties

// What are our invariants ??

// 1. The total supply of DSC should be less than the total value of collateral
// 2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;
    address USER = makeAddr('user');
    address TOKEN = makeAddr('token');

  function setUp() external {
    deployer = new DeployDSC();
    (dsc, dsce, config) = deployer.run();
    (,,weth,wbtc,) = config.activeNetworkConfig();
    // targetContract(address(dsce));
    handler = new Handler(dsce, dsc); 
    targetContract(address(handler)); // now that the target is the handler and the handler only has depositCollateral as a function,
    // it's gonna always break on that one
    // dont call redeemCollateral, unless there is collateral to redeem => create a handler for that 
  }

  function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
    // get the value of all the collateral in the protocol
    // compare it to all the debt (dsc)
    uint256 totalSupply = dsc.totalSupply();
    uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
    uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));
    uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
    uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

    console.log("weth value: ", wethValue);
    console.log("wbtc value: ", wbtcValue);
    console.log("totalSupply: ", totalSupply);

    assert(wethValue + wbtcValue >= totalSupply);
  }

  function invariant_gettersShouldNotRevert() public {
    dsce.getCollateralTokens();
    dsce.getCollateralBalanceOfUser(USER, TOKEN);
    // etc
  }
}