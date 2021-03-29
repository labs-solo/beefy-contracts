// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../../interfaces/common/IUniswapRouter.sol";
import "../../interfaces/hyperjump/IHyperCity.sol";
import "../../interfaces/hyperjump/IHyperPool.sol";

/**
 * @dev Implementation of a strategy to get yields from farming a {mechs} pool + base {alloy} farming.
 *
 * The strategy simply deposits whatever {alloy} it receives from the vault into the HyperCity getting {mechs} in exchange.
 * This {mechs} is then allocated into the configured pool (HyperPool). Rewards generated by the HyperPool can be harvested,
 * swapped for more {alloy}, and deposited again for compound farming. Rewards from the HyperCity are also compounded.
 *
 * This strat is currently compatible with all {mechs} pools.
 * The output token and its corresponding HyperPool is configured with a constructor argument
 */
contract StrategyMechs is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {alloy} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {mechs} - Intermediate token generated by staking {alloy} in the HyperCity.
     * {bifi} - BeefyFinance token, used to send funds to the treasury.
     * {output} - Token generated by staking {alloy}.
     */
    address constant public wbnb  = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public alloy = address(0x5eF5994fA33FF4eB6c82d51ee1DC145c546065Bd);
    address constant public mechs  = address(0x3ae713C662B8852D686e718E0762631A4CB84954);
    address constant public hypr = address(0x03D6BD3d48F956D783456695698C407A46ecD54d);
    address constant public bifi  = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);
    address public output;

    /**
     * @dev Third Party Contracts:
     * {unirouter} - StreetSwap unirouter
     * {hyperCity} - HyperCity contract. Stake {alloy}, get {mechs}.
     * {hyperPool} - HyperPool contract. Stake {mechs}, get {output} token.
     */
    address constant public unirouter = address(0x3bc677674df90A9e5D741f28f6CA303357D0E4Ec);
    address constant public hyperCity = address(0x4F1818Ff649498a2441aE1AD29ccF55a8E1C6250);
    address public hyperPool;

    /**
     * @dev Beefy Contracts:
     * {rewards} - Reward pool where the strategy fee earnings will go.
     * {treasury} - Address of the BeefyFinance treasury
     * {vault} - Address of the vault that controls the strategy's funds.
     */
    address constant public rewards = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C);
    address constant public treasury = address(0x4A32De8c248533C28904b24B4cFCFE18E9F2ad01);
    address constant public hyperdao = address(0x62f4deb9895a95276b03E38ABea8b0B315e8C3c1);
    address public vault;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on chargeFees().
     * Current implementation separates 6% for fees.
     *
     * {REWARDS_FEE} - 2% goes to BIFI holders through the {rewards} pool.
     * {CALL_FEE} - 0.5% goes to whoever executes the harvest function as gas subsidy.
     * {TREASURY_FEE} - 0.5% goes to the treasury.
     * {HYPER_FEE} - 1.5% goes to the hyper team.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public REWARDS_FEE  = 444;
    uint constant public CALL_FEE     = 111;
    uint constant public TREASURY_FEE = 111;
    uint constant public HYPER_FEE    = 334;
    uint constant public MAX_FEE      = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using StreetSwap.
     * {outputToAlloyRoute} - Route we take to get from {output} into {alloy}.
     * {outputToWbnbRoute} - Route we take to get from {output} into {wbnb}.
     * {wbnbToBifiRoute} - Route we take to get from {wbnb} into {bifi}.
     */
    address[] public outputToAlloyRoute;
    address[] public outputToWbnbRoute;
    address[] public wbnbToBifiRoute = [wbnb, bifi];
    address[] public wbnbToHyprRoute = [wbnb, hypr];

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the HyperPool and Vault that it will use.
     */
    constructor(address _hyperPool, address _vault) public {
        hyperPool = _hyperPool;
        vault = _vault;
        output = IHyperPool(hyperPool).rewardToken();

        outputToAlloyRoute = [output, wbnb, alloy];
        outputToWbnbRoute = [output, wbnb];

        IERC20(output).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {alloy} in the HyperCity to receive {mechs}
     * It then deposits the received {mechs} in the HyperPool to farm {output}.
     */
    function deposit() public whenNotPaused {
        uint256 alloyBal = IERC20(alloy).balanceOf(address(this));

        if (alloyBal > 0) {
            IERC20(alloy).safeApprove(hyperCity, 0);
            IERC20(alloy).safeApprove(hyperCity, alloyBal);
            IHyperCity(hyperCity).enterStaking(alloyBal);

            uint256 mechsBal = IERC20(mechs).balanceOf(address(this));
            IERC20(mechs).safeApprove(hyperPool, 0);
            IERC20(mechs).safeApprove(hyperPool, mechsBal);
            IHyperPool(hyperPool).deposit(mechsBal);
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {mechs} from the HyperPool, the {mechs} is switched back to {alloy}.
     * The resulting {alloy} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 alloyBal = IERC20(alloy).balanceOf(address(this));

        if (alloyBal < _amount) {
            uint256 mechsBal = IERC20(mechs).balanceOf(address(this));
            IHyperPool(hyperPool).withdraw(_amount.sub(alloyBal).sub(mechsBal));

            mechsBal = IERC20(mechs).balanceOf(address(this));
            if (mechsBal > _amount) {
                mechsBal = _amount;
            }

            IHyperCity(hyperCity).leaveStaking(mechsBal);
            alloyBal = IERC20(alloy).balanceOf(address(this));
        }

        if (alloyBal > _amount) {
            alloyBal = _amount;    
        }
        
        uint256 _fee = alloyBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
        IERC20(alloy).safeTransfer(vault, alloyBal.sub(_fee));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the HyperCity & HyperPool
     * 2. It swaps the {output} token for {alloy}
     * 3. It charges the system fee and sends it to BIFI stakers.
     * 4. It re-invests the remaining profits.
     */
    function harvest() public whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");
        IHyperCity(hyperCity).leaveStaking(0);
        IHyperPool(hyperPool).deposit(0);
        chargeFees();
        swapRewards();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 4.5% as system fees from the rewards. 
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(alloy).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouter(unirouter).swapExactTokensForTokens(toWbnb, 0, outputToWbnbRoute, address(this), now.add(600));
    
        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);
        
        uint256 treasuryHalf = wbnbBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wbnb).safeTransfer(treasury, treasuryHalf);
        IUniswapRouter(unirouter).swapExactTokensForTokens(treasuryHalf, 0, wbnbToBifiRoute, treasury, now.add(600));
        
        uint256 rewardsFee = wbnbBal.mul(REWARDS_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewards, rewardsFee);
        
        uint256 hyperFee = wbnbBal.mul(HYPER_FEE).div(MAX_FEE);
        IUniswapRouter(unirouter).swapExactTokensForTokens(hyperFee, 0, wbnbToHyprRoute, hyperdao, now.add(600));
    }

    /**
     * @dev Swaps whatever {output} it has for more {alloy}.
     */
    function swapRewards() internal {
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        IUniswapRouter(unirouter).swapExactTokensForTokens(outputBal, 0, outputToAlloyRoute, address(this), now.add(600));
    }

    /**
     * @dev Function to calculate the total underlaying {alloy} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the HyperPool.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfAlloy().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {alloy} the contract holds.
     */
    function balanceOfAlloy() public view returns (uint256) {
        return IERC20(alloy).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {alloy} the strategy has allocated in the HyperCity
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IHyperCity(hyperCity).userInfo(0, address(this));
        return _amount;
    }

    /**
     * @dev Function that gets called as part of strat migration. It sends all the available funds back to the 
     * vault, ready to be migrated to the new strat.
     */ 
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IHyperPool(hyperPool).emergencyWithdraw();
        
        uint256 mechsBal = IERC20(mechs).balanceOf(address(this));
        IHyperCity(hyperCity).leaveStaking(mechsBal);

        uint256 alloyBal = IERC20(alloy).balanceOf(address(this));
        IERC20(alloy).transfer(vault, alloyBal);
    }

    /**
     * @dev Withdraws all funds from the HyperPool & HyperCity, leaving rewards behind.
     * It also reduces allowance of the unirouter
     */
    function panic() public onlyOwner {
        pause();

        IHyperPool(hyperPool).emergencyWithdraw();
        
        uint256 mechsBal = IERC20(mechs).balanceOf(address(this));
        IHyperCity(hyperCity).leaveStaking(mechsBal);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(output).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(output).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
    }
}
