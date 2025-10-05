// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AlgoToken.sol";
import "../src/AlgoBond.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "abdk/ABDKMathQuad.sol";
import {console} from "forge-std/console.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1e10 * 10**6); // 10B USDC
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract AlgoTokenTest is Test {
    AlgoToken public algoToken;
    AlgoBond public algoBond;
    MockUSDC public usdc;

    using ABDKMathQuad for uint256;
    using ABDKMathQuad for int256;
    using ABDKMathQuad for bytes16;
    
    address public alice = address(0x1);
    address public bob = address(0x2);

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

    // absolute value function for bytes16
    function abs(bytes16 val) private pure returns (bytes16) {
        if (val.cmp(uint256(0).fromUInt()) < 0) {
            return val.neg();
        }
        return val;
    }

    // absolute value function for int256
    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
    
    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();
        
        // Setup test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        
        // Transfer USDC to test accounts
        console.log("Mint usdc for alice:");
        usdc.transfer(alice, 1e9 * 10**6);

        console.log("Mint usdc for bob:");
        usdc.transfer(bob, 100000 * 10**6);
    }
    
    // function testInitialState() public {
    //     // Add your initial state tests
    //     assertEq(algoToken.name(), "Algo Token");
    //     assertEq(algoToken.symbol(), "AT");
    // }

    // Test with fuzzing
    function testFuzz_All(
        uint256 kValueScaled,
        uint256 ATH_peg_padding,
        uint256 bear_current,
        uint256 initial_price,
        uint256[100] memory actions,
        uint256[100] memory amounts  
    ) 
    public {
        // kValueScaled = bound(kValueScaled, 1.00001e5, 10e5); 
        kValueScaled = bound(kValueScaled, 1.001e5, 10e5); 
        console.log("kValueScaled:", kValueScaled);
        bytes16 k = uint256(kValueScaled).fromUInt().div(uint256(1e5).fromUInt());
        
        ATH_peg_padding = bound(ATH_peg_padding, 1e6 * 10**usdc.decimals(), 100e6 * 10**usdc.decimals());
        bear_current = bound(bear_current, 0, 15e6); //0 to 5 years
        console.log("initial bear_current", bear_current);

        initial_price = bound(initial_price, 10**usdc.decimals() / 1e3, 10 * 10**usdc.decimals()); // $.001 to $10.000
        console.log("initial_price:", initial_price);

        // constructor(
        //     uint256 ATH_peg_padding_,
        //     uint256 bear_current_,
        //     bytes16 K_,
        //     uint256 price_,
        //     string memory name_,
        //     string memory symbol_,
        //     string memory algoBond_Name_,
        //     string memory algoBond_Symbol_,
        //     address input_stableCoin,
        //     bytes16 bondPortionAtMaturity_,
        //     uint256 minimum_block_length_between_bondSum_updates_
        // )

        // Deploy AlgoToken with test parameters
        // You'll need to adjust based on your constructor
        algoToken = new AlgoToken(
            ATH_peg_padding,
            bear_current,
            k,
            initial_price,
            "Algo Token",
            "AT",
            "Algo Bond",
            "AB",
            usdc,
            0x3ffb851eb851eb851eb851eb851eb852,  // bondPortionAtMaturity = 1/e^2
            216000 // minimum_block_length_between_bondSum_updates_ = 1 month
        );

        // Simulate sequence of actions
        uint256 USDC_decimals_scale_factor = 10**usdc.decimals();
        bytes16 price = algoToken.price();
        uint256 buy_amount;
        bytes16 supply_normalization_factor = algoToken.supply_normalization_factor();
        bool peg_reached_peg_target = false;
        uint256 peg_target = algoToken.peg_target();
        bytes16 ATH_price = algoToken.ATH_price();

        uint i = 0;
        // Bootstrap by buying an initial amount and then letting some time go by
        // Buy
        // buy_amount = bound(amounts[i], 1 * USDC_decimals_scale_factor, 1e6 * USDC_decimals_scale_factor);
        buy_amount = bound(amounts[i], 100 * USDC_decimals_scale_factor, 10e6 * USDC_decimals_scale_factor);
        console.log("buy amount:", buy_amount);
        vm.startPrank(alice);
        usdc.approve(address(algoToken), buy_amount);
        if (usdc.balanceOf(alice) >= buy_amount) {
            algoToken.buy(buy_amount);
            console.log("new circ_supply:", algoToken.circ_supply());
        }
        vm.stopPrank();
        if (algoToken.peg() >= algoToken.peg_target()) {
            peg_reached_peg_target = true;
        }

        i = 1;
        // Time travel
        uint256 amount = bound(amounts[i], 3600, 604800); //measured in seconds (range between 1 hour and 1 week)
        vm.warp(block.timestamp + amount);
        vm.roll(block.number + amount / 12); // Assuming 12 seconds per block

        // run Update() to complete boostrap
        algoToken.update();

        for (i = 1; i < actions.length; i++) {
            uint256 action = actions[i] % 4;
                
            console.log("i:", i);

            if (algoToken.reserve() > 10**usdc.decimals() || algoToken.price().cmp(algoToken.ATH_price()) >= 0) {
                // Then, the AMM is still functional

                console.log("algoToken.reserve()", algoToken.reserve());

                if (action == 0) {
                    // Buy
                    // buy_amount = bound(amounts[i], 1 * USDC_decimals_scale_factor, 1e6 * USDC_decimals_scale_factor);
                    buy_amount = bound(amounts[i], 100 * USDC_decimals_scale_factor, 10e6 * USDC_decimals_scale_factor);
                    console.log("buy amount:", buy_amount);
                    vm.startPrank(alice);
                    usdc.approve(address(algoToken), buy_amount);
                    if (usdc.balanceOf(alice) >= buy_amount) {
                        algoToken.buy(buy_amount);
                        console.log("new circ_supply:", algoToken.circ_supply());
                    }
                    vm.stopPrank();
                    if (algoToken.peg() >= algoToken.peg_target()) {
                        peg_reached_peg_target = true;
                        assertTrue(
                            algoToken.peg() == algoToken.peg_target(),
                            "Invariant Failed: peg > peg_target"
                        );
                        
                        assertTrue(
                            algoToken.bear_current().cmp(f_0) == 0,
                            "bear_current != 0 after peg reached peg_target"
                        ); 
                    }
                    
                } else if (action == 1) {
                    // Sell
                    vm.startPrank(alice);
                    uint256 balance = algoToken.balanceOf(alice);
                    // uint256 amount = bound(amounts[i], 1 * AT_decimals_scale_factor, 1e6 * AT_decimals_scale_factor);
                    
                    uint256 sell_amount;
                    if (peg_reached_peg_target) {
                        // Sell more agressively than buying so that peg eventually reaches 0
                        sell_amount = bound(amounts[i], 0, balance);
                        console.log("sell_amount:", sell_amount);
                    }
                    else {
                        // Sell amount merasured in USD is 1/2 of the previous buy amount so that
                        // the peg pool will eventually reach peg_target
                        sell_amount = buy_amount.fromUInt().div(algoToken.price()).mul(supply_normalization_factor).toUInt()/2;
                    } 
                    sell_amount = min(sell_amount, balance);
                    console.log("Selling: balance:", balance);

                    if (balance > 0) {
                        algoToken.sell(sell_amount);
                    }

                    vm.stopPrank();
                } else if (action == 2) {
                    // Update
                    algoToken.update();
                    
                } else {
                    // Time travel
                    amount = bound(amounts[i], 3600, 604800); //measured in seconds (range between 1 hour and 1 week)
                    vm.warp(block.timestamp + amount);
                    vm.roll(block.number + amount / 12); // Assuming 12 seconds per block
                }

            } else {
                //Then, Reserve has been depleted, which means the AMM is no longer functional.
                // Calls to buy(), sell(), or update() will revert  
                break;
            }

            // Test invariants
            bytes16 K = algoToken.K();
            bytes16 Ky = min(K, algoToken.K_target());
            assertTrue(Ky.cmp(algoToken.Ky()) == 0, "Invariant failed: Ky != min(K, K_target)");
            bytes16 Kx = max(algoToken.Ky(), algoToken.K_real());
            assertTrue(Kx.cmp(algoToken.Kx()) == 0, "Invariant failed: Kx != max(Ky, K_real)");

            uint256 peg = algoToken.peg();
            bytes16 f_peg = algoToken.f_peg();
            assertTrue(
                peg == f_peg.toUInt(), 
                "Invariant failed: algoToken.peg() != algoToken.f_peg()"
            );

            uint256 slip = algoToken.slip();
            bytes16 f_slip = algoToken.f_slip();
            assertTrue(
                slip == f_slip.toUInt(),
                "Invariant failed: algoToken.slip() != algoToken.f_slip()"
            );

            uint256 reserve = peg + slip;
            bytes16 f_reserve = f_peg.add(f_slip);
            assertTrue(reserve == algoToken.f_reserve().toUInt(), "Invariant failed: algoToken.f_reserve() != peg + slip");
            assertTrue(reserve == algoToken.reserve(), "Invariant failed: reserve != algoToken.reserve()");


            bytes16 peg_min = (Kx.mul(f_slip).add(f_peg).div(pow(Ky, f_2)));
            if (peg > peg_min.toUInt()) {
                assertTrue(
                    algoToken.peg_min_safety().cmp(algoToken.peg_min_drain()) <= 0, 
                    "Invariant failed: peg_min_safety > peg_min_drain"
                );
            }

            uint256 i_peg_min_safety = algoToken.peg_min_safety().toUInt();
            ATH_peg_padding = algoToken.ATH_peg_padding();
            peg_target = algoToken.peg_target();
            assertTrue(
                abs(int256(peg_target) - int256(i_peg_min_safety + ATH_peg_padding)) < 10,
                "Invariant failed: peg_target != peg_min_safety + ATH_peg_padding"
            );

            uint256 hyp_supply = algoToken.hypothetical_supply();
            uint256 circ_supply = algoToken.circ_supply();
            assertTrue(hyp_supply >= circ_supply, "Invariant failed: hypothetical_supply < circ_supply");


            // real_Mcap = price * circ_supply
            price = algoToken.price();
            bytes16 real_Mcap = algoToken.real_Mcap();
            bytes16 f_circ_supply = algoToken.f_circ_supply();
            bytes16 real_Mcap_calculated = price.mul(f_circ_supply);
            assertTrue(
                abs(real_Mcap.sub(real_Mcap_calculated)).cmp(f_10) <=0,
                "Invariant failed: real_Mcap != price * circ_supply"
            );

            // target_Mcap = price * hyp_supply
            bytes16 target_Mcap = algoToken.target_Mcap();
            bytes16 f_hyp_supply = algoToken.f_hyp_supply();
            bytes16 target_Mcap_calculated = price.mul(f_hyp_supply);
            assertTrue(
                abs(target_Mcap.sub(target_Mcap_calculated)).cmp(f_10) <=0,
                "Invariant failed: target_Mcap != price * hyp_supply"
            );

            assertTrue(real_Mcap.sub(f_10).cmp(target_Mcap) <= 0, "Invariant failed: real_Mcap > target_Mcap");

            bytes16 K_real = algoToken.K_real();
            assertTrue(K_real.cmp(K) <= 0, "Invariant failed: K_real > K");

            if (action == 2) {
                // Then,  algoToken.update(); was run

                // real_Mcap = K_real * slip + peg
                real_Mcap_calculated = K_real.mul(f_slip).add(f_peg);
                assertTrue(
                    abs(real_Mcap.sub(real_Mcap_calculated)).cmp(f_10) <=0,
                    "Invariant failed: real_Mcap != K_real * slip + peg"
                );

                // target_Mcap = K * slip + peg
                target_Mcap_calculated = K.mul(f_slip).add(f_peg);
                assertTrue(
                    abs(target_Mcap.sub(target_Mcap_calculated)).cmp(f_10) <=0,
                    "Invariant failed: target_Mcap != K * slip + peg"
                );

                assertTrue(
                    algoToken.bear_estimate().cmp(algoToken.bear_current()) >= 0,
                    "Invariant failed: bear_estimate < bear_current"
                );

                assertTrue(
                    algoToken.bear_actual().cmp(algoToken.bear_current()) >= 0,
                    "Invariant failed: bear_actual < bear_current"
                );

                assertTrue(
                    algoToken.bear_actual().cmp(algoToken.bear_estimate()) >= 0,
                    "Invariant failed: bear_actual < bear_estimate"
                );
            }

            ATH_price = algoToken.ATH_price();
            if (peg > 0) {
                assertTrue(ATH_price.sub(price).cmp(f_10) <= 0, "Invariant failed: peg > 0 while price != ATH_price");
            }
            
            
            if (algoToken.bear_actual().cmp(uint256(220000).fromUInt()) > 0) {
                // Then the bear market is long enough that K_real would effectively never reach K.
                // As long as K_real is significantly less than K, slip can never reach 0.
                assertTrue(slip > 0, "Invariant failed, slip = 0 after algoToken.Update() ran at least once");
            }

            if (peg == 0) {
                // Then price = K * reserve / hyp_supply = K_real * reserve / circ_supply
                console.log("peg = 0: test invariants for bancor v1 formula");
                if (hyp_supply > 0) {
                    bytes16 calculated_price = K.mul(f_reserve).div(f_hyp_supply);
                    assertTrue(
                        abs(calculated_price.sub(price)).cmp(f_10) <=0,
                        "Invariant failed: price != K * reserve / hyp_supply"
                    );

                    if (circ_supply > 0) {
                        calculated_price = K_real.mul(f_reserve).div(f_circ_supply);
                        assertTrue(
                            abs(calculated_price.sub(price)).cmp(f_10) <=0,
                            "Invariant failed: price != K_real * reserve / circ_supply"
                        );
                    }
                    
                }
            }




        }

    }
}