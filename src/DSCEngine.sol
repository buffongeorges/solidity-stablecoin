// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author segroegg
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI has no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral be <= of the dollar-backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

        /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/
    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;  // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

        /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited (address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed (address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _; // à ne pas oublier !
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        // For example ETH/USD, BTC/USD, MKR/USD ...abi
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
      depositCollateral(tokenCollateralAddress, amountCollateral);
      mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI : Checks (modifiers), Effects, Interactions
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    /* whenever we are working with external contracts it's a good idea to make the function nonReentrant
    reentrances are one of the most common attacks in web3. It's most gas intensive but safer */ {

      // Effects
      s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
      emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

      // Interactions
      bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral); // transferFrom grace à IERC20
      if (!success) {
        revert DSCEngine__TransferFailed();
      }
    }

    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
      burnDsc(amountDscToBurn);
      redeemCollateral(tokenCollateralAddress, amountCollateral);
      // redeemCollateral already checks health factor
    }

    // in order to redeem collateral: 
    // 1. health factor > 1 AFTER collateral pulled
    // DRY: Don't repeat yourself

    // CEI : Check, Effects, Interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
      _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
      _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 1. Check if the collateral value > DSC amount. Price feeds, values
    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
      s_DSCMinted[msg.sender] += amountDscToMint;

      // if they minted too much ($150 DSC, $100ETH) => revert
      _revertIfHealthFactorIsBroken(msg.sender);
      bool minted = i_dsc.mint(msg.sender, amountDscToMint);
      if (!minted) {
        revert DSCEngine__MintFailed();
      }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
      _burnDsc(amount, msg.sender, msg.sender);
      _revertIfHealthFactorIsBroken(msg.sender); // I don't this would ever hit...
    }

    //$100 ETH
    // && $50 DSC this is good because we have more collateral than the value of our DSC

    // but $100 -> $60ETH
    // $50 DSC not good, we should liquidate the user because he's way too close to be undercollateralized
    // we should set a threshold for example 150%

    // If someone pays back your minted DSC, they can have all your collateral for a discount if they liquidate your position
    // This will incentivize people to always extra collateral otherwise they are gonna lose mor money than they borrow
    // If we do start nearing undercollateralization, we need someone to liquidate positions
    // $100 ETH backing $50 DSC
    // and then $20 ETH backing $50 DSC <- DSC isn't worth $1. Shouldnt happen!

    // if $75 backing $50 DSC
    // liquidator take $75 backing and burns off the $50 DSC
    // If someone is almost undercollateralized, we will pay you to liquidate them
    /**
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidate bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated
     * 
     * Follow CEI : Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant{
      // need to check health factor of the user
      uint256 startingUserHealthFactor = _healthFactor(user);

      if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
        revert DSCEngine__HealthFactorOk();
      }

      // We wanrt to burn their DSC "debt"
      // And take their collateral
      // Bad User: $140 ETH, $100 DSC. 
      // debtToCover = $100
      // $100 of DSC = ??? ETH
      // 0.05 ETH
      uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
      // And give them a 10% bonus
      // So we are giving the liquidators $110 of WETH for 100 DSC
      // We should implement a feature to liquidate in the event the protocol is insolvent
      // And sweep extra amounts into a treasury
      // 0.05 * 0.1 = 0.005 Getting 0.055
      uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
      uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
      _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);

      // We need to burn the DSC
      _burnDsc(debtToCover, user, msg.sender);

      uint256 endingUserHealthFactor = _healthFactor(user);
      if (endingUserHealthFactor <= startingUserHealthFactor) {
        revert DSCEngine__HealthFactorNotImproved();
      }
      _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

        /*//////////////////////////////////////////////////////////////
                      PRIVATE & INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
      // 100 - 1000 will revert => solidity compiler will crash automatically
      s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
      emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
      bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
      // .transfer => when you transfer from yourself
      // .transferFrom => from somebody else

      if (!success) {
        revert DSCEngine__TransferFailed();
      }
    }

    /* 
    * @dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken
    */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
      s_DSCMinted[onBehalfOf] -= amountDscToBurn;
      bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

      // This conditional is hypothetically unreachable because if transfer fails it will thorw its own error, but we'll leave it for backup
      if (!success) {
        revert DSCEngine__TransferFailed();
      }
      i_dsc.burn(amountDscToBurn);
    }

    function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
      totalDscMinted = s_DSCMinted[user];
      collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) { // on préfixe la fonction par _ pour indiquer à nous les dev que c'est une fonction interne
      // total DSC minted
      // total collateral VALUE
      (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
      uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
      return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
      // ex1: 100 ETH * 50 = 50,000/100 = 500

      // ex2: $1000 ETH & 100 DSC minted 
      // 150 * 50 = 7500 / 100 = 75 / 100 < 1
  
      // ex3 : $1000 ETH / & 100 DSC minted
      // 1000 * 50 = 50000 / 100 = (500 / 100) > 1
      // return (collateralValueInUsd / totalDscMinted); // (150 / 100)
    }

      // 1. Check health factor (do they have enough collateral ?)
      // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
      uint256 userHealthFactor = _healthFactor(user);
      if (userHealthFactor < MIN_HEALTH_FACTOR) {
        revert DSCEngine__BreaksHealthFactor(userHealthFactor);
      }
    }

        /*//////////////////////////////////////////////////////////////
                    PUBLIC & EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
      // price of ETH (token)
      // $/ETH ETH ??
      // $2000 / ETH. $1000 = 0.5 ETH
      AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
      (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

      // Example : ($10e18 * 1e18) / ($2000e8 * 1e10)
      return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
      // loop through each collateral token, get the amount they have deposited, and map it to the price to get the USD value
      for (uint256 i = 0; i < s_collateralTokens.length; i++) {
        address token = s_collateralTokens[i];
        uint256 amount = s_collateralDeposited[user][token];
        totalCollateralValueInUsd += getUsdValue(token, amount);
      }
      return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256){
      AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
      (,int256 price,,,) = priceFeed.staleCheckLatestRoundData();
      // if 1ETH = $1000
      // The returned value from Chainlink will be 1000 * 1e8 (1e8 because for ETH/USD the pricefeed will return 8 decimal places : see chainlink docs for that) 
      return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount)/PRECISION;
    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd){
      (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
      return (totalDscMinted, collateralValueInUsd);
    }

    function getCollateralTokens() external view returns (address[] memory) {
      return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
      return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
