// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "abdk/ABDKMathQuad.sol";
import "./AlgoBond.sol";
import {console} from "forge-std/console.sol";

/**
 * @title AlgoToken
 * @dev An algorithmic stablecoin that functions as a complete AMM with dual-pool architecture,
 * dynamic leverage adjustment, and bond mechanisms for supply management.
 * 
 * Key Features:
 * - Dual-pool system (peg pool for stable trades, slip pool for leveraged backing)
 * - Algorithmic price growth through market cap expansion
 * - Dynamic parameter adjustment based on market conditions
 * - Bond system for locking supply and enabling higher leverage
 * - Bear market discovery mechanism for calibrating growth rates
 */
contract AlgoToken is ERC20 {

    // ============================================
    // LIBRARIES
    // ============================================
    
    // Using 128-bit quadruple precision floating point math for accuracy
    // This prevents rounding errors that could accumulate over time
    using ABDKMathQuad for uint256;
    using ABDKMathQuad for int256;
    using ABDKMathQuad for bytes16;

    // ============================================
    // EXTERNAL CONTRACTS
    // ============================================
    
    ERC20 public stableCoin; // The USD-pegged token held in reserves (e.g., USDC, DAI)
    AlgoBond public algoBond; // NFT bond contract for locking AlgoTokens

    // ============================================
    // MATHEMATICAL CONSTANTS (bytes16 = quadruple precision float)
    // ============================================
    
    bytes16 f_0 = uint256(0).fromUInt(); // 0.0 as float
    bytes16 f_1 = uint256(1).fromUInt(); // 1.0 as float
    bytes16 f_2 = uint256(2).fromUInt(); // 2.0 as float
    bytes16 f_1_2 = f_1.div(f_2); // 0.5 as float
    bytes16 f_10 = uint256(10).fromUInt(); // 10.0 as float
    bytes16 f_golden_ratio = 0x3fff9e3779b97f68151235e290029709; // 1.61803398875 (used for bond maturity calculations)

    // ============================================
    // ERC20 STATE VARIABLES
    // ============================================
    
    bytes16 public supply_normalization_factor = uint256(10**decimals()).fromUInt();

    // ============================================
    // PRICE AND SUPPLY VARIABLES
    // ============================================
    
    /**
     * @dev Current price of AlgoToken in USD
     */
    bytes16 public price;
    
    /**
     * @dev All-time high price - acts as the peg price
     * Sales execute at this price when peg pool has funds
     */
    bytes16 public ATH_price;
    
    /**
     * @dev Current circulating supply of AlgoTokens
     * Increases from buys and bond interest, decreases from sales
     */
    uint256 public circ_supply = 0;
    
    /**
     * @dev Highest recorded circulating supply since the last bear market ended
     * Used to calculate expected supply selloff percentage
     */
    uint256 public highest_circ_supply_since_bear_end = circ_supply;
    
    /**
     * @dev Hypothetical supply used for Bancor formula calculations
     * Represents the supply if all market cap growth went to new tokens
     * Real supply is split between new tokens (bonds) and price appreciation
     */
    uint256 public hypothetical_supply = circ_supply;

    // float versions for calculations
    bytes16 public f_hyp_supply = hypothetical_supply.fromUInt().div(supply_normalization_factor);
    bytes16 public f_circ_supply = circ_supply.fromUInt().div(supply_normalization_factor);

    // ============================================
    // MARKET CAP VARIABLES
    // ============================================
    
    /**
     * @dev Real market cap = price * circ_supply
     * The actual value of all circulating tokens
     */
    bytes16 public real_Mcap = f_0;
    
    /**
     * @dev Target market cap that real_Mcap approaches over time
     * Determined by K * slip + peg
     */
    bytes16 public target_Mcap = f_0;
    
    /**
     * @dev Idealized market cap based on K_target
     * Represents what market cap should be with optimal leverage
     */
    bytes16 public idealized_Mcap = f_0;

    // ============================================
    // LEVERAGE CONSTANTS (K VALUES)
    // ============================================
    
    /**
     * @dev K - Primary leverage constant (Bancor v1)
     * Determines both:
     * 1. Backing ratio: Market Cap = K * Reserve
     * 2. Price slippage severity when trading in slip pool
     * Higher K = more leverage but more severe slippage
     */
    bytes16 public K;
    
    /**
     * @dev K_real - Actual current market leverage
     * Calculated from real market cap and reserves
     * Converges toward K over time
     */
    bytes16 public K_real = f_1;
    
    /**
     * @dev K_target - Target leverage based on bond lockups
     * Higher bond participation allows higher K_target
     * K slowly grows toward K_target
     */
    bytes16 public K_target;
    
    /**
     * @dev Kx = max(K_real, Ky)
     * Used in peg_min calculations (numerator)
     * Represents the actual leverage that must be defended
     */
    bytes16 public Kx;
    
    /**
     * @dev Ky = min(K, K_target)
     * Used in peg_min calculations (denominator)
     * Represents the conservative leverage for sizing reserves
     */
    bytes16 public Ky;

    // ============================================
    // SUPPLY SELLOFF EXPECTATIONS
    // ============================================
    
    /**
     * @dev Expected percentage of supply that might be sold
     * Calculated as: 1 - (bonds_locked / highest_circ_supply)
     * Lower values allow higher leverage (K_target)
     */
    bytes16 public expected_supply_selloff;
    
    /**
     * @dev Maximum allowed expected_supply_selloff
     * Safety limit to prevent excessive leverage
     * Prevents K_target from approaching infinity if expected selloff approaches 100%
     * Since K_target = sqrt(1/expected_supply_selloff), this cap is essential
     */
    bytes16 public max_expected_supply_selloff;

    /**
     * @dev actual supply selloff amount in the current bear market
     * When the current bear market ends, if it was considered "major" and 
     * the actual selloff is lower than the current expected_supply_selloff, then
     * expected_supply_selloff is updated to be equal to 
     * highest_actual_supply_selloff_of_current_bear_market
     * and K and K_target are updated accordingly.  This allows K to appreciate
     * independently from the amount of supply locked in bonds.
     */
    bytes16 public highest_actual_supply_selloff_of_current_bear_market;

    // ============================================
    // RESERVE POOLS
    // ============================================
    
    /**
     * @dev Total USD reserves = slip + peg
     */
    uint256 public reserve = 0;
    
    /**
     * @dev Slip pool - Leveraged reserve using Bancor v1
     * Price slips up/down when trading against this pool
     */
    uint256 public slip = 0;
    
    /**
     * @dev Peg pool - 1:1 backed reserve at ATH price
     * Trades execute at ATH price with zero slippage
     */
    uint256 public peg = 0;
    
    // Float versions for calculations
    bytes16 public f_slip = slip.fromUInt();
    bytes16 public f_peg = peg.fromUInt();
    bytes16 public f_reserve = reserve.fromUInt();

    // ============================================
    // PEG POOL MINIMUM THRESHOLDS
    // ============================================
    
    /**
     * @dev Minimum peg size to handle expected selloff
     * Below this, the peg could break from normal selling
     */
    bytes16 public peg_min_safety = f_0;
    
    /**
     * @dev Target peg size for drainage calculations
     * Peg pool exponentially drains toward this level
     */
    bytes16 public peg_min_drain = f_0;
    
    /**
     * @dev All-time high of (peg - peg_min_safety)
     * Represents the maximum safety buffer achieved
     */
    uint256 public ATH_peg_padding;
    
    /**
     * @dev Target peg size = peg_min_safety + ATH_peg_padding
     * Bear markets end when peg reaches this level
     */
    uint256 public peg_target;

    // ============================================
    // DEMAND SCORES
    // ============================================
    
    /**
     * @dev Measures peg strength for bear market calculations
     * Range: 0 to 1, where 1 = peg at target
     * Drives the decay rate of bear_estimate when bear_estimate > bear_current
     * Higher score = faster bear_estimate decays toward bear_current
     */
    bytes16 public demand_score_safety = f_0;
    
    /**
     * @dev Determines peg drainage rate from peg pool into slip pool
     * Higher score = faster drainage allowed
     * Score = (peg - peg_min_drain) / (peg_target - peg_min_drain)
     */
    bytes16 public demand_score_drainage = f_0;

    // ============================================
    // DRAINAGE PARAMETERS
    // ============================================

    /**
     * @dev USD amount in slip pool when price equals ATH
     * Used to calculate slippage requirements
     */
    uint256 public slip_that_reaches_ATH_price = 0;

    // ============================================
    // BEAR MARKET TRACKING
    // ============================================
    
    /**
     * @dev Length of the last "major" bear market in blocks
     * Used to calibrate all time-dependent parameters
     */
    bytes16 public bear_actual;
    
    /**
     * @dev Current bear market length in blocks
     * Increments while peg < peg_target, resets when peg >= peg_target
     */
    bytes16 public bear_current;
    
    /**
     * @dev Estimated length of next major bear market
     * Dynamically adjusts based on market conditions
     */
    bytes16 public bear_estimate;
    
    // Block tracking for updates
    uint256 public block_index_of_last_bear_market_update = block.number;
    uint256 public block_index_of_last_update = block.number;
    
    // Time since last update (in blocks)
    uint256 private t_t0 = block.number - block_index_of_last_update;
    bytes16 private f_t_t0 = t_t0.fromUInt();

    // ============================================
    // BOND PARAMETERS
    // ============================================
    
    /**
     * @dev Minimum blocks between bond sum updates (e.g., 1 month = 219000 blocks)
     * Prevents excessive gas costs from frequent updates
     */
    uint256 public minimum_block_length_between_bondSum_updates;
    
    /**
     * @dev Bond portion at which immediate redemption triggers
     * E.g., 0.1 = redeem fully when bond decays to 10% of original
     */
    bytes16 public bondPortionAtMaturity;
    
    /**
     * @dev Total AlgoTokens locked in bonds
     * Reduces expected selloff pressure
     */
    uint256 public total_algos_locked_in_bonds = 0;

    // ============================================
    // CONSTRUCTOR
    // ============================================
    
    /**
     * @param ATH_peg_padding_ Initial reserve padding above minimum safety level
     * @param bear_current_ Starting bear market length in blocks
     * @param K_ Initial leverage constant (e.g., 1.2 = 20% leveraged)
     * @param price_ starting price
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param algoBond_Name_ Bond NFT name
     * @param algoBond_Symbol_ Bond NFT symbol
     * @param input_stableCoin input USD stablecoin for reserves
     * @param bondPortionAtMaturity_ Threshold for bond acceleration
     * @param minimum_block_length_between_bondSum_updates_ Min blocks between updates
     */
    constructor(
        uint256 ATH_peg_padding_,
        uint256 bear_current_,
        bytes16 K_,
        uint256 price_,
        string memory name_,
        string memory symbol_,
        string memory algoBond_Name_,
        string memory algoBond_Symbol_,
        ERC20 input_stableCoin,
        bytes16 bondPortionAtMaturity_,
        uint256 minimum_block_length_between_bondSum_updates_
    )
    ERC20 (name_, symbol_) 
    {
        // Initialize padding and target
        ATH_peg_padding = ATH_peg_padding_;
        peg_target = ATH_peg_padding_;

        // Initialize bear market tracking
        bear_current = bear_current_.fromUInt();
        bear_actual = bear_current;
        bear_estimate = bear_current;

        // Initialize leverage constants
        K = K_;
        K_target = K_;
        console.log("Constructor: K", K.mul(uint256(100).fromUInt()).toUInt());
        console.log("Constructor: K_target", K_target.mul(uint256(100).fromUInt()).toUInt());
        Ky = min(K, K_target);
        Kx = max(K_real, Ky);
        
        // Calculate initial expected selloff
        expected_supply_selloff = f_1.div(Kx.mul(Kx));
        max_expected_supply_selloff = expected_supply_selloff;
        highest_actual_supply_selloff_of_current_bear_market = expected_supply_selloff;

        // Set bond parameters
        bondPortionAtMaturity = bondPortionAtMaturity_;

        // Deploy bond contract
        algoBond = new AlgoBond(algoBond_Name_, algoBond_Symbol_, address(this), bondPortionAtMaturity_);
        
        // Set stablecoin
        stableCoin = input_stableCoin;

        // Set the price
        price = price_.fromUInt();
        ATH_price = price;

        minimum_block_length_between_bondSum_updates = minimum_block_length_between_bondSum_updates_;
    }

    // ============================================
    // ERC20 OVERRIDES
    // ============================================

    // function _approve(
    //     address owner,
    //     address spender,
    //     uint256 amount
    // ) internal override {
    //     require(owner != address(0), "ERC20: approve from the zero address");
    //     require(spender != address(0), "ERC20: approve to the zero address");

    //     _allowances[owner][spender] = amount;
    //     emit Approval(owner, spender, amount);
    // }

    // ============================================
    // MATHEMATICAL HELPER FUNCTIONS
    // ============================================
    
    /**
     * @dev Calculate y^z using logarithms
     * Formula: y^z = 2^(z * log_2(y))
     */
    function pow(bytes16 y, bytes16 z) private pure returns(bytes16) {
        bytes16 log_y = y.log_2();
        bytes16 z_log_y = z.mul(log_y);
        return z_log_y.pow_2();
    }

    // Max/min functions for different types
    function max(uint256 a, uint256 b) private pure returns (uint256) {
        return a >= b ? a : b;
    }
    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a <= b ? a : b;
    }
    function max(bytes16 a, bytes16 b) private pure returns (bytes16) {
        return a.cmp(b) >= 0 ? a : b;
    }
    function min(bytes16 a, bytes16 b) private pure returns (bytes16) {
        return a.cmp(b) <= 0 ? a : b;
    }
    function max(int256 a, int256 b) private pure returns (int256) {
        return a >= b ? a : b;
    }
    function min(int256 a, int256 b) private pure returns (int256) {
        return a <= b ? a : b;
    }

    // ============================================
    // PRINT STRING FUNCTIONS
    // ============================================

    function scale(bytes16 input, uint256 scale_factor) private pure returns (uint256) {
        return input.mul(scale_factor.fromUInt()).toUInt();
    }

    // ============================================
    // CORE AMM FUNCTIONS
    // ============================================
    
    /**
     * @dev Buy AlgoTokens with USD
     * 
     * Process:
     * 1. If price < ATH: USD goes to slip pool, price slips up (Bancor v1)
     * 2. If price = ATH: USD goes to peg pool, no slippage
     * 3. Updates bear market tracking if peg_target reached
     * 4. Adjusts K values based on new market state
     */
    function buy(uint USD_amount) public {
        console.log("slip:", slip);
        console.log("reserve:", reserve);
        require(
            price.cmp(ATH_price) >= 0 || slip > 10**stableCoin.decimals(),
            "slip = 0 rendering AMM non-functional"
        );

        // Transfer will revert if user doesn't have funds or allowance
        stableCoin.transferFrom(msg.sender, address(this), USD_amount);

        uint256 USD_remaining = USD_amount;
        uint256 algos_to_mint = 0;
        bool price_increased = false;
        
        // ========== PRICE BELOW ATH - SLIP POOL TRADING ==========
        if (price.cmp(ATH_price) < 0) {
            // Price is below ATH, so peg pool must be empty
            // USD goes into slip pool, causing upward price slippage
            
            uint256 new_hyp_supply; // New hypothetical supply after Bancor formula
            
            if (USD_remaining < slip_that_reaches_ATH_price - slip) {
                // Purchase won't reach ATH price
                // Apply Bancor v1 formula to entire amount
                
                uint256 new_slip = slip + USD_remaining;
                console.log("new_slip:", new_slip);
                console.log("slip:", slip);
                console.log("K", scale(K, 1e30));

                // Bancor v1: S/S0 = (R/R0)^(1/K)
                // New supply = Old supply * (New reserve / Old reserve)^(1/K)
                console.log("before Bancor v1 calculation");
                new_hyp_supply = 
                hypothetical_supply.fromUInt().mul(
                    pow(
                        new_slip.fromUInt().div(slip.fromUInt()),
                        f_1.div(K)
                    )
                ).toUInt();

                console.log("Bancor v1 calculation complete");

                algos_to_mint = new_hyp_supply - hypothetical_supply;
                slip = new_slip;
                f_slip = slip.fromUInt();
                f_hyp_supply = new_hyp_supply.fromUInt().div(supply_normalization_factor);
                price = K.mul(f_slip).div(f_hyp_supply); // P = K * R/S
                USD_remaining = 0;
                circ_supply += algos_to_mint;
            }
            else {
                // Purchase will reach ATH price
                // First, fill slip pool to exact ATH level
                
                console.log("ATH_price", scale(ATH_price, 1e30));
                console.log("price", scale(price, 1e30));
                price = ATH_price;
                USD_remaining -= slip_that_reaches_ATH_price - slip;
                console.log("slip_that_reaches_ATH_price", slip_that_reaches_ATH_price);
                console.log("slip", slip);
                
                new_hyp_supply = 
                hypothetical_supply.fromUInt().mul(
                    pow(
                        slip_that_reaches_ATH_price.fromUInt().div(slip.fromUInt()),
                        f_1.div(K)
                    )
                ).toUInt();
                
                slip = slip_that_reaches_ATH_price;
                algos_to_mint += new_hyp_supply - hypothetical_supply;  
                circ_supply += algos_to_mint;
            }
            
            reserve = slip;
            hypothetical_supply = new_hyp_supply;
            price_increased = true;
        }

        // ========== PRICE AT ATH - PEG POOL TRADING ==========
        console.log("ATH_price before price.cmp(ATH_price)", ATH_price.toUInt());
        if (price.cmp(ATH_price) >= 0) {
            console.log("price.cmp(ATH_price) >= 0");
            // Price has reached ATH
            // Remaining USD goes into peg pool with zero slippage
            
            peg += USD_remaining;
            reserve = slip + peg;

            // Update ATH padding if we've exceeded previous highs
            ATH_peg_padding = uint256(max(
                int256(max(0, int(peg) - peg_min_safety.toInt())),
                int256(ATH_peg_padding)
            ));

            // Mint tokens at ATH price
            console.log("USD_remaining:", USD_remaining);
            uint256 algos_to_add_to_mint = USD_remaining.fromUInt().div(price).mul(supply_normalization_factor).toUInt();
            console.log("algos_to_add_to_mint:", algos_to_add_to_mint);
            algos_to_mint += algos_to_add_to_mint;
            console.log("hypothetical_supply before adding algos_to_add_to_mint:", hypothetical_supply);
            hypothetical_supply += algos_to_add_to_mint;
            console.log("hypothetical_supply after adding algos_to_add_to_mint:", hypothetical_supply);
            circ_supply += algos_to_add_to_mint;
            
            // Check if bear market has ended
            uint256 new_peg_target = ATH_peg_padding + peg_min_safety.toUInt();
            if (new_peg_target > peg_target) {
                // Bear market has ended!
                peg_target = new_peg_target;
                
                uint256 blocks_since_last_bear_update = block.number - block_index_of_last_bear_market_update;
                bear_current = bear_current.add(blocks_since_last_bear_update.fromUInt()); 

                // Check if this was a "major" bear market
                if (bear_current.add(f_10).cmp(bear_estimate) >= 0) { 
                    // Update our bear market benchmarks
                    console.log("bear_actual before updating", bear_actual.toUInt());
                    console.log("bear_estimate before updating", bear_estimate.toUInt());
                    console.log("bear_current", bear_current.toUInt());
                    bear_actual = bear_current;
                    bear_estimate = bear_current;
                    console.log(
                        "highest_actual_supply_selloff_of_current_bear_market", 
                        highest_actual_supply_selloff_of_current_bear_market.mul(uint256(1e40).fromUInt()).toUInt()
                    );
                    console.log(
                        "expected_supply_selloff before updated to highest_actual_supply_selloff_of_current_bear_market", 
                        expected_supply_selloff.mul(uint256(1e40).fromUInt()).toUInt()
                    );
                    expected_supply_selloff = highest_actual_supply_selloff_of_current_bear_market;
                    // Cap at maximum allowed
                    if (expected_supply_selloff.cmp(max_expected_supply_selloff) > 0) {
                        expected_supply_selloff = max_expected_supply_selloff;
                    }
                    console.log(
                        "expected_supply_selloff after end of major bear market", 
                        expected_supply_selloff.mul(uint256(1e40).fromUInt()).toUInt());
                    console.log("K before updated at end of major bear market", K.mul(uint256(1e5).fromUInt()).toUInt());
                    K = min(f_1.div(expected_supply_selloff).sqrt(), uint256(100).fromUInt());
                    K_target = max(K_target, K);
                    console.log("K after updated at end of major bear market", K.mul(uint256(1e5).fromUInt()).toUInt());
                    calculate_peg_min_safety_and_peg_target();
                }

                highest_actual_supply_selloff_of_current_bear_market = f_0;
                
                // Reset bear market counter
                bear_current = f_0;
                highest_circ_supply_since_bear_end = circ_supply;
                block_index_of_last_bear_market_update = block.number;
            }
        }

        // Update highest supply tracker
        if (circ_supply > highest_circ_supply_since_bear_end) {
            highest_circ_supply_since_bear_end = circ_supply;
        }

        // Update all market cap calculations
        f_hyp_supply = hypothetical_supply.fromUInt().div(supply_normalization_factor);
        f_circ_supply = circ_supply.fromUInt().div(supply_normalization_factor);
        f_slip = slip.fromUInt();
        f_peg = peg.fromUInt();
        real_Mcap = price.mul(f_circ_supply);
        console.log("real_Mcap = ", real_Mcap.toUInt());
        console.log("circ_supply", circ_supply);

        idealized_Mcap = K_target.mul(f_slip).add(f_peg);

        target_Mcap = price.mul(f_hyp_supply);
        console.log("price = ", price.toUInt());
        console.log("target_Mcap = ", target_Mcap.toUInt());
        console.log("hypothetical_supply", hypothetical_supply);

        if (price_increased) {
            // Update K_real based on new market state
            // K_real = (Market Cap - Peg) / Slip
            console.log("K_real after price increased but before being updated", K_real.mul(uint256(1e30).fromUInt()).toUInt());
            K_real = real_Mcap.sub(f_peg).div(f_slip);
            // If K_real > K due to rounding error, round K_real downwards towards K
            K_real = min(K_real, K);
            console.log("K_real after price increased and after being updated", K_real.mul(uint256(1e30).fromUInt()).toUInt());
            console.log("price_increased");
        }

        update_K_target();

        // Update minimum peg requirements
        calculate_peg_min_drain();
        calculate_demand_score_drainage();
        
        // Complete the trade
        _mint(msg.sender, algos_to_mint);
    }

    /**
     * @dev Sell AlgoTokens for USD
     * 
     * Process:
     * 1. If peg pool has funds: Sell at ATH price, deplete peg
     * 2. If peg pool empty: Sell to slip pool, price slips down
     * 3. Updates K values based on actual selloff
     */
    function sell(uint algo_amount) public {

        // Transfer will revert if user doesn't have required token balance or allowance
        _burn(msg.sender, algo_amount);
        console.log("burned");

        uint256 algos_remaining = algo_amount;
        uint USD_to_send = 0;
        bool price_decreased = false;

        // ========== SELL TO PEG POOL FIRST ==========
        if (peg > 0) {
            console.log("peg > 0");

            uint256 algos_to_subtract;
            uint256 peg_decrease = price.mul(algos_remaining.fromUInt()).div(supply_normalization_factor).toUInt();
            
            if (peg_decrease >= peg) {
                // Deplete entire peg pool
                USD_to_send = peg;
                algos_to_subtract = peg.fromUInt().div(price).mul(supply_normalization_factor).toUInt();
                algos_remaining -= algos_to_subtract;
                peg = 0;
                reserve = slip;
            }
            else {
                // Partial peg depletion
                USD_to_send = peg_decrease;
                peg -= USD_to_send;
                reserve = peg + slip;
                algos_to_subtract = algos_remaining;
                algos_remaining = 0;
            }
            
            circ_supply -= algos_to_subtract;
            hypothetical_supply -= algos_to_subtract;
        }

        // ========== SELL TO SLIP POOL IF PEG EMPTY ==========
        if (peg == 0) {
            console.log("peg = 0, sell to slip pool");

            // Apply Bancor v1 formula for downward slippage
            uint256 new_hyp_supply = hypothetical_supply - algos_remaining;

            // R/R0 = (S/S0)^K
            uint256 new_slip = slip.fromUInt().mul(
                pow(
                    new_hyp_supply.fromUInt().div(hypothetical_supply.fromUInt()),
                    K
                )
            ).toUInt();

            USD_to_send += slip - new_slip;
            slip = new_slip;
            console.log("slip", slip);
            reserve = slip;
            hypothetical_supply = new_hyp_supply;
            console.log("hypothetical_supply", hypothetical_supply);
            circ_supply -= algos_remaining;
            console.log("circ_supply", circ_supply);
            algos_remaining = 0;
            f_hyp_supply = hypothetical_supply.fromUInt().div(supply_normalization_factor);
            f_reserve = reserve.fromUInt();
            price = K.mul(f_reserve.div(f_hyp_supply)); // P = K * R/S
            console.log("price", price.toUInt());
            price_decreased = true;
        }

        
        // Update market caps
        f_hyp_supply = hypothetical_supply.fromUInt().div(supply_normalization_factor);
        console.log("f_hyp_supply", f_hyp_supply.mul(uint256(1e30).fromUInt()).toUInt());
        f_circ_supply = circ_supply.fromUInt().div(supply_normalization_factor);
        console.log("f_circ_supply", f_circ_supply.mul(uint256(1e30).fromUInt()).toUInt());
        f_slip = slip.fromUInt();
        f_peg = peg.fromUInt();
        real_Mcap = price.mul(f_circ_supply);
        idealized_Mcap = K_target.mul(f_slip).add(f_peg);
        target_Mcap = price.mul(f_hyp_supply);

        if (slip > 0) {
            // Then, the AMM is still functional.  Once slip == 0, 
            // the AMM is completely empty and stops functioning because the bancor v1 formula
            // relies on measuring the percentage change in slip.
            // If slip is 0, then the percentage change is infinity.
            // the smart contract would need to be redeployed/bootstrapped.
            // The code in this if-block crashes if slip == 0.

            if (price_decreased) {
                // Update K_real for new lower price
                console.log("K_real after price decreased but before being updated", K_real.mul(uint256(1e30).fromUInt()).toUInt());
                K_real = real_Mcap.div(f_slip);
                // If K_real > K due to rounding error, round K_real downwards towards K
                K_real = min(K_real, K);
                console.log("K_real after price decreased and after being updated", K_real.mul(uint256(1e30).fromUInt()).toUInt());
                console.log("price_decreased");
            }

            update_K_target();
            console.log("Update_K_target() completed");

            // Update peg requirements
            calculate_peg_min_drain();
            console.log("calculate_peg_min_drain() completed");
            calculate_demand_score_drainage();
            console.log("calculate_demand_score_drainage() completed");
        }

        // Complete the trade
        stableCoin.approve(address(this), USD_to_send);
        stableCoin.transferFrom(address(this), msg.sender, USD_to_send);
    }

    /**
     * @dev Main update function - called periodically to update system state
     * 
     * Updates:
     * 1. Drains peg to slip if appropriate
     * 2. Grows K_real towards K
     * 3. Adjusts all dynamic parameters
     * 4. Increments bear market counters
     */
    function update() public {

        //require(circ_supply > 0, "circ_supply = 0. run buy() first before running update().");
        
        t_t0 = block.number - block_index_of_last_update;
        f_t_t0 = t_t0.fromUInt();
        f_peg = peg.fromUInt();
        f_slip = slip.fromUInt();
        f_reserve = reserve.fromUInt();

        console.log("t_t0", t_t0);
         
        if (t_t0 > 0 && real_Mcap.toUInt() >= 10 ** stableCoin.decimals()) {
            // At least 1 block has passed, do the update
            
            console.log("K_real before update", K_real.mul(uint256(1e30).fromUInt()).toUInt());
            console.log("K before update", K.mul(uint256(1e30).fromUInt()).toUInt());

            if (f_peg.cmp(peg_min_safety) > 0) {
                console.log("drain_peg_into_slip()");
                drain_peg_into_slip();
            }
            
            console.log("update_K_target()");
            update_K_target();

            console.log("update_target_Mcap_K_real_and_K()");
            update_target_Mcap_K_real_and_K();

            console.log("grow_K_real_towards_K()");
            grow_K_real_towards_K();

            console.log("calculate_peg_min_safety_and_peg_target()");
            calculate_peg_min_safety_and_peg_target();

            console.log("increment_bear_current_and_manage_bear_estimate_and_bear_actual()");
            increment_bear_current_and_manage_bear_estimate_and_bear_actual();

            console.log("K_real after update", K_real.mul(uint256(1e30).fromUInt()).toUInt());
            console.log("K after update", K.mul(uint256(1e30).fromUInt()).toUInt());
        }
    }

    /**
     * @dev Gradually drains USD from peg pool to slip pool
     * 
     * The drainage uses a weighted average mechanism to adapt the rate:
     * - Vanilla formula: peg approaches peg_min_drain asymptotically
     * - Modified by W: When W < 1, drainage accelerates as if target were lower
     * 
     * Drainage rate depends on demand score and bear market length
     * Increases the amount of reserves that are leveraged (moves USD from peg to slip)
     */
    function drain_peg_into_slip() private {
        calculate_peg_min_drain();

        uint256 peg0 = peg; // Save initial peg value
        f_peg = peg.fromUInt();

        calculate_demand_score_drainage();

        // ============================================
        // WEIGHTED AVERAGE DRAINAGE MECHANISM
        // ============================================
        
        /**
         * The drainage formula:
         * peg = peg_min_drain + (peg0 - peg_min_drain) * e^(-(t-t0) / (T*W))
         * 
         * Where W is the weighted average that modifies drainage speed:
         * W = 1 - C * peg_min_drain/peg
         * 
         * How W affects drainage:
         * - W = 1 (vanilla): peg drains toward peg_min_drain normally
         * - W < 1 (accelerated): peg drains faster, as if target were lower than peg_min_drain
         * - W much less than 1: peg drains as if target were near zero
         * 
         * The economic logic:
         * - High demand (C near 1): W becomes small, allowing aggressive drainage
         * - Low demand (C near 0): W approaches 1, preserving capital with vanilla rate
         */
        
        // Calculate weighted average
        // This is NOT averaging two rates, but rather modifying the vanilla rate
        // When demand is high, W < 1 accelerates drainage beyond the natural equilibrium
        bytes16 weighted_average = 
        f_1.sub(demand_score_drainage.mul(
            peg_min_drain.div(f_peg)
        ));
        
        /**
         * Example with numbers:
         * If peg_min_drain = 730, peg = 900, demand_score = 0.89:
         * W = 1 - 0.89 * (730/900) = 1 - 0.72 = 0.28
         * 
         * This makes T*W much smaller than T, accelerating drainage 3.6x
         * The peg drains as if aiming for a target well below peg_min_drain
         */

        // Step size relative to bear market length
        // CRITICAL: step_size represents the discrete time step as a fraction of bear_estimate
        // If updates are infrequent (large t-t0), step_size becomes large, which can cause
        // the demand_score to jump discontinuously rather than decay smoothly
        // The system expects frequent updates (e.g., daily) to maintain granularity
        // If we fail to maintain adequate granularity, we use the vanilla formula which omits the weighted_average
        bytes16 step_size = f_t_t0.div(bear_estimate); 

        bytes16 f_peg_minus_peg_min_drain = f_peg.sub(peg_min_drain);
        if (f_peg_minus_peg_min_drain.cmp(f_10) >= 0) {
            // Peg significantly above minimum, calculate drainage
            
            /**
             * Apply the exponential drainage formula with weighted time constant:
             * - Vanilla (W=1): peg approaches peg_min_drain
             * - Modified (W<1): peg drains faster, potentially toward zero
             * 
             * The division by weighted_average in the exponent is key:
             * - Smaller W → larger exponent → faster decay
             */
            f_peg = peg_min_drain.add(
                f_peg.sub(peg_min_drain).div(
                    step_size.div(weighted_average).exp()
                )
            );
        }
        
        bytes16 previous_demand_score_drainage = demand_score_drainage;
        calculate_demand_score_drainage();

        // Check if drainage rate is too aggressive
        // This can happen when step_size isn't granular enough to capture the 
        // continuous change in demand_score_drainage that should occur from drainage.
        // The demand score naturally decreases as peg drains (since peg is in the numerator),
        // but if blocks between updates are too large, the discrete jump in demand score
        // exceeds what natural continuous drainage would have produced.
        // Example: If 100 blocks pass between updates when the system expects ~10 blocks,
        // the demand score might drop by 0.1 when continuous drainage would only drop it 0.01
        if (previous_demand_score_drainage.sub(demand_score_drainage).cmp(step_size) > 0){
            // Use vanilla exponential decay instead (without weighted_average modification)
            // This prevents discontinuous jumps in drainage rate that would occur
            // from using the discretely-calculated demand score
            // The vanilla formula simply uses e^(-step_size) without the weighted_average acceleration
            demand_score_drainage = previous_demand_score_drainage.div(step_size.exp());
            
            // Calculate peg that corresponds to this smoothed demand score
            // This ensures peg follows a continuous path rather than jumping
            f_peg = peg_min_drain.add(
                demand_score_drainage.mul(peg_target.fromUInt().sub(peg_min_drain))
            );
        }

        peg = f_peg.toUInt();
        if (peg <= peg_min_drain.toUInt()) {
            // Round to avoid numerical issues
            f_peg = peg.fromUInt();
        }
        
        // Move drained USD to slip pool
        uint256 peg_peg0 = peg0 - peg;
        slip += peg_peg0;
        f_slip = slip.fromUInt();
    }

    /**
     * @dev Grows K_real towards K over time
     * Creates algorithmic market cap growth and price appreciation
     * Some of the market cap growth goes to minting new supply for bond holders,
     * and the rest goes towards price appreciation for all token holders
     * Rate depends on bear market length and peg status
     */
    function grow_K_real_towards_K() private {
        // Exponential convergence: K_real = K - (K - K_real0) * e^(-(t-t0) / T)
        
        bytes16 K_K_real0 = K.sub(K_real);
        bytes16 t_t0_T = f_t_t0.div(bear_actual);
        bytes16 e_t_t0_T = t_t0_T.exp();
        bytes16 K_K_real_0_div_e_t_t0_T = K_K_real0.div(e_t_t0_T);
        K_real = K.sub(K_K_real_0_div_e_t_t0_T);
        
        // If K_real > K due to rounding error, round K_real downwards towards K
        K_real = min(K_real, K);

        // Ensure no negative values from rounding
        f_slip = max(f_slip, f_0);
        f_peg = max(f_peg, f_0);
        
        bytes16 K_real_slip = K_real.mul(f_slip);
        bytes16 previous_Mcap = real_Mcap;
        
        // Calculate new market cap from K_real growth
        real_Mcap = K_real_slip.add(f_peg);
        
        // Market cap gain to be distributed
        bytes16 market_cap_gain = real_Mcap.sub(previous_Mcap);
        
        total_algos_locked_in_bonds = algoBond.getTotalAlgosLockedInBonds();
        
        if (total_algos_locked_in_bonds > 0) {
            // Distribute gains between bond holders and price appreciation
            
            // Bond ratio determines portion of market cap gains that goes to 
            // newly minted supply distributed to bond holders
            bytes16 bondRatio = total_algos_locked_in_bonds.fromUInt().div(
                highest_circ_supply_since_bear_end.fromUInt()
            );
            
            // Up to half of proportional gains go to bonds as new supply
            bytes16 Mcap_to_mint = market_cap_gain.mul(bondRatio).mul(f_1_2);
            
            // Mint tokens for bond holders (distributed later)
            uint256 algos_to_mint = Mcap_to_mint.div(price).mul(supply_normalization_factor).toUInt();
            circ_supply += algos_to_mint;
            highest_circ_supply_since_bear_end += algos_to_mint;
            algoBond.addToGainsAccrual(algos_to_mint);
        }
        
        total_algos_locked_in_bonds = algoBond.getTotalAlgosLockedInBonds();
        
        // Update price from new market cap
        // Price always increases because market cap growth > supply growth
        f_circ_supply = circ_supply.fromUInt().div(supply_normalization_factor);
        price = real_Mcap.div(f_circ_supply);
        ATH_price = max(price, ATH_price);
        
        // Update hypothetical supply
        f_hyp_supply = target_Mcap.div(price);
        hypothetical_supply = f_hyp_supply.mul(supply_normalization_factor).toUInt();

        // CHeck for invariant that can fail due to rounding error
        if (hypothetical_supply < circ_supply) {
            hypothetical_supply = circ_supply;
        }
    }

    /**
     * @dev Updates K_target based on bond participation and actual selloff
     * 
     * Two drivers:
     * 1. Bond lockups increase/decrease → K_target increases/decreases respectively
     *    However, K_target cannot go below K when adjusting due to bond lockups alone
     * 2. Excessive selling (actual > expected) → K_target forced below K (conservative mode)
     */
    function update_K_target() private {
        // Calculate expected selloff based on bonds
        total_algos_locked_in_bonds = algoBond.getTotalAlgosLockedInBonds();
        bytes16 f_highest_circ_supply_since_bear_end = highest_circ_supply_since_bear_end.fromUInt();
        
        expected_supply_selloff = f_1.sub(
            total_algos_locked_in_bonds.fromUInt().div(f_highest_circ_supply_since_bear_end)
        );
        console.log("expected_supply_selloff algos locked in bonds:", expected_supply_selloff.mul(uint256(1e40).fromUInt()).toUInt());
        
        // Cap at K-implied selloff
        console.log("hello");
        //console.log("K", K.mul(uint256(1e5).fromUInt()).toUInt());
        bytes16 expected_supply_selloff_as_per_K = f_1.div(pow(K, f_2));
        console.log("K", scale(K, 1e40));
        console.log("hello again");
        console.log("expected_supply_selloff_as_per_K", expected_supply_selloff_as_per_K.mul(uint256(1e40).fromUInt()).toUInt());
        expected_supply_selloff = min(expected_supply_selloff, expected_supply_selloff_as_per_K);
        console.log("expected_supply_selloff after min check", expected_supply_selloff.mul(uint256(1e40).fromUInt()).toUInt());

        // Check actual selloff
        bytes16 actual_supply_selloff = f_1.sub(
            circ_supply.fromUInt().div(f_highest_circ_supply_since_bear_end)
        );

        console.log("circ_supply", circ_supply);
        console.log("highest_circ_supply_since_bear_end", highest_circ_supply_since_bear_end);
        console.log("actual_supply_selloff:", actual_supply_selloff.mul(uint256(1e40).fromUInt()).toUInt());

        if (actual_supply_selloff.cmp(highest_actual_supply_selloff_of_current_bear_market) > 0) {
            highest_actual_supply_selloff_of_current_bear_market = actual_supply_selloff;
        }

        // If actual worse than expected, update expectations
        if (actual_supply_selloff.cmp(expected_supply_selloff) > 0) {
            expected_supply_selloff = actual_supply_selloff;
        }
        
        // Cap at maximum allowed
        if (expected_supply_selloff.cmp(max_expected_supply_selloff) > 0) {
            expected_supply_selloff = max_expected_supply_selloff;
        }
        
        console.log("expected_supply_selloff:", expected_supply_selloff.mul(uint256(1e40).fromUInt()).toUInt());
        console.log("max_expected_supply_selloff:", max_expected_supply_selloff.mul(uint256(1e40).fromUInt()).toUInt());

        // Calculate K_target from selloff expectations
        // K_target = sqrt(1 / expected_supply_selloff)
        console.log("K_target before being updated:", K_target.mul(uint256(1e40).fromUInt()).toUInt());
        K_target = f_1.div(expected_supply_selloff).sqrt();
        console.log("K_target after being updated:", K_target.mul(uint256(1e40).fromUInt()).toUInt());

        idealized_Mcap = K_target.mul(f_slip).add(f_peg);
    }

    /**
     * @dev Updates target market cap and K values based on drainage
     * Handles both growth mode (K_target > K) and conservative mode (K_target < K)
     */
    function update_target_Mcap_K_real_and_K() private {
        if (f_slip.cmp(f_10) >= 0) {
            // Update K_real from drainage (K_real decreases as drainage moves USD from peg to slip)
            bytes16 real_Mcap_peg = real_Mcap.sub(f_peg);
            if (real_Mcap_peg.cmp(f_10) >= 0) {
                K_real = real_Mcap_peg.div(f_slip);
            }
            
            console.log("K_target before if: ", K_target.mul(uint256(100000000000).fromUInt()).toUInt());
            console.log("K before if: ", K.mul(uint256(100000000000).fromUInt()).toUInt());
            console.log("K_target.cmp(K)",K_target.cmp(K));

            if (K_target.cmp(K) < 0) {
                // Conservative mode: K decreases from drainage
                // Target market cap stays constant
                bytes16 target_Mcap_peg = target_Mcap.sub(f_peg);
                if (target_Mcap_peg.cmp(f_10) >= 0) {
                    console.log("target_Mcap_peg.cmp(f_10) >= 0.   K before: ", K.mul(uint256(100).fromUInt()).toUInt());
                    K = max(K_target, target_Mcap_peg.div(f_slip)); // Do not decrease K below K_Target
                    console.log("target_Mcap_peg.cmp(f_10) >= 0.   K after: ", K.mul(uint256(100).fromUInt()).toUInt());
                }
            }

            int8 K_Target_cmp_K = K_target.cmp(K);
            if (K_Target_cmp_K > 0) {
                // Growth mode: K grows towards K_target
                // Formula: K = K_target - (K_target - K0) * e^(-(t-t0) / (bear_actual * K_target/K0))
                bytes16 f_Kt_minus_K0 = K_target.sub(K);
                bytes16 f_Ta_Kt_div_K0 = bear_actual.mul(K_target.div(K));
                bytes16 f_exponent = f_t_t0.div(f_Ta_Kt_div_K0);
                console.log("K before K_target sub   K: ", K.mul(uint256(100).fromUInt()).toUInt());
                K = K_target.sub(
                    f_Kt_minus_K0.div(f_exponent.exp())
                );
                console.log("K after K_target sub   K: ", K.mul(uint256(100).fromUInt()).toUInt());
            }

            if (K_Target_cmp_K >= 0) {
                // Update target market cap
                target_Mcap = K.mul(f_slip).add(f_peg);
            }
            
            
        }
    }

    /**
     * @dev Calculates minimum safe peg size and target
     * Updates as drainage changes the slip/peg ratio
     */
    function calculate_peg_min_safety_and_peg_target() private {
        bytes16 tmp_f_slip;
        
        if (ATH_price.sub(price).cmp(f_10) <= 0) {
            console.log("ATH_price.sub(price).cmp(f_10) <= 0");
            console.log("f_slip:", f_slip.toUInt());
            //console.log("f_slip = %s", f_slip);
            // At ATH price
            slip_that_reaches_ATH_price = slip;
            //console.log("slip_that_reaches_ATH_price = %s", slip_that_reaches_ATH_price);
            tmp_f_slip = f_slip.cmp(f_10) >= 0 ? f_slip : f_0;
            //console.log("tmp_f_slip = %s", tmp_f_slip);
        }
        else {
            console.log("ELSE OF: ATH_price.sub(price).cmp(f_10) <= 0");
            // Below ATH - calculate slip needed to reach it
            // Uses Bancor formula: R = R0 * (P_ATH/P)^(1/(1-1/K))
            slip_that_reaches_ATH_price = 
            f_reserve.mul(
                pow(
                    ATH_price.div(price),
                    f_1.div(f_1.sub(f_1.div(K)))
                )
            ).toUInt();
            
            tmp_f_slip = slip_that_reaches_ATH_price.fromUInt();
        }
        
        if (tmp_f_slip.cmp(f_10) >= 0) {
            console.log("tmp_f_slip.cmp(f_10) >= 0");
            // Update Kx and Ky
            Ky = min(K, K_target);
            Kx = max(K_real, Ky);
            console.log("K:", K.mul(uint256(100).fromUInt()).toUInt());
            console.log("K_target:", K_target.mul(uint256(100).fromUInt()).toUInt());
            console.log("K_real:", K_real.mul(uint256(1e30).fromUInt()).toUInt());
            console.log("Ky:", Ky.mul(uint256(100).fromUInt()).toUInt());
            console.log("Kx:", Kx.mul(uint256(100).fromUInt()).toUInt());
            
            // Calculate minimum safe peg size
            // peg_min_safety = Kx * slip / (Ky^2 - 1)

            peg_min_safety = Kx.mul(tmp_f_slip).div(Ky.mul(Ky).sub(f_1));
            console.log("peg_min_safety:", peg_min_safety.toUInt());
        }
        else {
            console.log("ELSE OF: tmp_f_slip.cmp(f_10) >= 0");
            peg_min_safety = f_0;
        }
        
        calculate_peg_target();
    }

    /**
     * @dev Updates bear market counters and estimates
     * Tracks current bear length and adjusts estimates of future bears
     */
    function increment_bear_current_and_manage_bear_estimate_and_bear_actual() private {
        uint256 blocks_since_last_bear_update = block.number - block_index_of_last_bear_market_update;
        
        // Modulate growth rate by demand when appropriate
        bytes16 modified_blocks_since_last_bear_update;
        if (bear_current.cmp(bear_estimate) >= 0) {
            // Near end of expected bear - slow growth if peg recovering
            modified_blocks_since_last_bear_update = f_1.sub(demand_score_drainage).mul(
                blocks_since_last_bear_update.fromUInt()
            );
        } else {
            modified_blocks_since_last_bear_update = blocks_since_last_bear_update.fromUInt();
        }
        
        bear_current = bear_current.add(modified_blocks_since_last_bear_update);
        
        if (bear_estimate.cmp(bear_current) >= 0) {
            // Decay bear_estimate towards bear_current
            bytes16 f_peg_minus_peg_min_safety = f_peg.sub(peg_min_safety);
            
            if (f_peg_minus_peg_min_safety.cmp(f_10) >= 0
                && bear_estimate.cmp(f_10) >= 0) {
                
                demand_score_safety = f_peg.sub(peg_min_safety).div(ATH_peg_padding.fromUInt());
                // Bear estimate decay formula: bear_estimate = bear_estimate0 * e^(-demand_score_safety * (t-t0) / bear_actual)
                bear_estimate = bear_estimate.mul(
                    demand_score_safety.neg().mul(f_t_t0).div(bear_actual).exp()
                );
                
                if (bear_estimate.cmp(bear_current) <= 0) {
                    bear_estimate = bear_current;
                }
            }
            else {
                demand_score_safety = f_0;
            }
        }
        else {
            // Bear longer than expected - update estimates
            if (bear_current.cmp(bear_estimate) > 0) {
                bear_estimate = bear_current;
            }
            if (bear_current.cmp(bear_actual) >= 0) {
                bear_actual = bear_current;
            }
        }
        
        block_index_of_last_bear_market_update = block.number;
        block_index_of_last_update = block.number;
    }

    /**
     * @dev Calculates demand score for drainage rate
     * Higher score = more aggressive drainage allowed
     */
    function calculate_demand_score_drainage() private {
        bytes16 f_peg_minus_peg_min_drain = f_peg.sub(peg_min_drain);
        
        if (f_peg_minus_peg_min_drain.cmp(f_10) >= 0) {
            // Calculate score: (peg - peg_min) / (peg_target - peg_min)
            demand_score_drainage = 
            f_peg_minus_peg_min_drain.div(
                peg_target.fromUInt().sub(peg_min_drain)
            );
        }
        else {
            demand_score_drainage = f_0;
        }
    }

    /**
     * @dev Calculates the equilibrium peg size for drainage
     * Peg exponentially approaches this level
     */
    function calculate_peg_min_drain() private {
        console.log("inside calculate_peg_min_drain()");
        
        f_reserve = reserve.fromUInt();
        console.log("inside calculate_peg_min_drain(), after f_reserve");
        Ky = min(K, K_target);
        console.log("inside calculate_peg_min_drain(), after Ky");
        console.log("calculate_peg_min_drain(), Ky:", Ky.mul(uint256(1e5).fromUInt()).toUInt());
        console.log("calculate_peg_min_drain(), K_real:", K_real.mul(uint256(1e5).fromUInt()).toUInt());
        Kx = max(K_real, Ky);
        console.log("inside calculate_peg_min_drain(), after Kx");
        console.log("calculate_peg_min_drain(), Kx:", Kx.mul(uint256(1e5).fromUInt()).toUInt());
        bytes16 Kx_reserve = Kx.mul(f_reserve);
        console.log("inside calculate_peg_min_drain(), after Kx_reserve");
        console.log("calculate_peg_min_drain(), Kx_reserve:", Kx_reserve.mul(uint256(1e5).fromUInt()).toUInt());
        
        

        // peg_min_drain = Kx * reserve / (Ky^2 + Kx - 1)
        bytes16 Kt_Kt = Ky.mul(Ky);
        bytes16 Kt2_Kx_1 = Kt_Kt.add(Kx).sub(f_1);
        peg_min_drain = Kx_reserve.div(Kt2_Kx_1);
    }

    /**
     * @dev Updates peg_target based on minimum safety and padding
     */
    function calculate_peg_target() private {
        uint256 i_peg_min_safety = peg_min_safety.toUInt();
        peg_target = max(peg, i_peg_min_safety + ATH_peg_padding);
        ATH_peg_padding = peg_target - i_peg_min_safety;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================
    
    function totalSupply() public view virtual override returns (uint256) {
        return circ_supply;
    }

    // ============================================
    // BOND FUNCTIONS
    // ============================================
    
    /**
     * @dev Buy a bond by locking AlgoTokens
     * @param algoAmount Amount of AlgoTokens to lock
     * @param bondType Type of bond (DECAY, GAINSONLY, or REINVEST)
     */
    function buyBond(uint256 algoAmount, AlgoBond.BondReturnsOption bondType) public {
        transferFrom(msg.sender, address(this), algoAmount);
        algoBond.mint(msg.sender, algoAmount, bondType);
        update_K_target();
    }

    /**
     * @dev Add more AlgoTokens to an existing bond
     * @param algoAmount Amount to add
     * @param tokenId Bond NFT ID
     */
    function addToBond(uint256 algoAmount, uint256 tokenId) public {
        transferFrom(msg.sender, address(this), algoAmount);
        uint256 algosToPayOut = algoBond.addToBond(tokenId, algoAmount);
        int256 netAlgosToPayOut = int256(algoAmount) - int256(algosToPayOut);
        
        if (netAlgosToPayOut > 0) {
            transferFrom(address(this), msg.sender, uint256(netAlgosToPayOut));
        }
        else if (netAlgosToPayOut < 0) {
            transferFrom(msg.sender, address(this), uint256(-netAlgosToPayOut));
        }
        
        update_K_target();
    }

    /**
     * @dev Update a bond to claim accumulated gains
     * @param tokenId Bond NFT ID
     */
    function updateBond(uint256 tokenId) public {
        require(msg.sender == algoBond.ownerOf(tokenId));
        
        uint256 algosToPayOut = algoBond.updateBond(tokenId);
        
        if (algosToPayOut > 0) {
            transfer(msg.sender, algosToPayOut);
        }
        
        update_K_target();
    }

    /**
     * @dev Change bond type (DECAY, GAINSONLY, REINVEST)
     * @param tokenId Bond NFT ID
     * @param bondType New bond type
     */
    function ChangeBondType(uint256 tokenId, AlgoBond.BondReturnsOption bondType) public {
        require(msg.sender == algoBond.ownerOf(tokenId));
        
        uint256 algosToPayOut = algoBond.ChangeBondType(tokenId, bondType);
        
        if (algosToPayOut > 0) {
            transfer(msg.sender, algosToPayOut);
        }
        
        update_K_target();
    }

    /**
     * @dev Update all bond sums - distributes accumulated gains
     * Can only be called after minimum block delay
     */
    function updateBondSums() public {
        // Set maturity timespan based on bear market length
        algoBond.setMaturityTimeSpan(f_golden_ratio.mul(bear_actual));
        
        // Distribute gains to bond holders
        algoBond.updateBondSums();
        
        update_K_target();
    }

    // ============================================
    // GETTER FUNCTIONS
    // ============================================
    
    function getBondReturnsOption_Decay() public pure returns (AlgoBond.BondReturnsOption) {
        return AlgoBond.BondReturnsOption.DECAY;
    }

    function getBondReturnsOption_GainsOnly() public pure returns (AlgoBond.BondReturnsOption) {
        return AlgoBond.BondReturnsOption.GAINSONLY;
    }

    function getBondReturnsOption_Reinvest() public pure returns (AlgoBond.BondReturnsOption) {
        return AlgoBond.BondReturnsOption.REINVEST;
    }

    function getMaturityTimeSpan() public view returns (bytes16) {
        return algoBond.maturityTimeSpan();
    }

    function _bDelayedSum() public view returns (uint256) {
        return algoBond._bDelayedSum();
    }

    function _bDelayedDecaySum() public view returns (uint256) {
        return algoBond._bDelayedDecaySum();
    }

    function _bDelayedGainsOnlySum() public view returns (uint256) {
        return algoBond._bDelayedGainsOnlySum();
    }

    function _bDelayedReinvestSum() public view returns (uint256) {
        return algoBond._bDelayedReinvestSum();
    }
}