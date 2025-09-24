// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AlgoToken.sol";
import "../src/AlgoBond.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "abdk/ABDKMathQuad.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10**6); // 1M USDC
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
    
    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();
        
        // Setup test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        
        // Transfer USDC to test accounts
        usdc.transfer(alice, 100000 * 10**6);
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
        uint256[10] memory actions,
        uint256[10] memory amounts  
    ) 
    public {
        kValueScaled = bound(kValueScaled, 1.00001e5, 10e5); 
        bytes16 k = uint256(kValueScaled).fromUInt().div(uint256(1e5).fromUInt());
        
        ATH_peg_padding = bound(ATH_peg_padding, 1e6 * 10**usdc.decimals(), 100e6 * 10**usdc.decimals());
        bear_current = bound(bear_current, 0, 15e6); //0 to 5 years

        // constructor(
        //     uint256 ATH_peg_padding_,
        //     uint256 bear_current_,
        //     bytes16 K_,
        //     string memory name_,
        //     string memory symbol_,
        //     string memory algoBond_Name_,
        //     string memory algoBond_Symbol_,
        //     address stableCoin_contract_address,
        //     bytes16 bondPortionAtMaturity_,
        //     uint256 minimum_block_length_between_bondSum_updates_
        // )

        // Deploy AlgoToken with test parameters
        // You'll need to adjust based on your constructor
        algoToken = new AlgoToken(
            ATH_peg_padding,
            bear_current,
            k,
            "Algo Token",
            "AT",
            "Algo Bond",
            "AB",
            address(usdc),
            0x3ffb851eb851eb851eb851eb851eb852,  // bondPortionAtMaturity = 1/e^2
            216000 // minimum_block_length_between_bondSum_updates_ = 1 month
        );

    // Simulate sequence of actions
    uint256 AT_decimals_scaled = 10**algoToken.decimals();
    uint256 USDC_decimals_scaled = 10**usdc.decimals();
    for (uint i = 0; i < 10; i++) {
        uint256 action = actions[i] % 4;
             
        if (action == 0) {
            // Buy
            uint256 amount = bound(amounts[i], 1 * USDC_decimals_scaled, 1e6 * USDC_decimals_scaled);
            vm.prank(alice);
            usdc.approve(address(algoToken), amount);
            vm.prank(alice);
            if (usdc.balanceOf(alice) >= amount) {
                algoToken.buy(amount);
            }
        } else if (action == 1) {
            // Sell
            uint256 amount = bound(amounts[i], 1 * AT_decimals_scaled, 1e6 * AT_decimals_scaled);
            vm.prank(alice);
            uint256 balance = algoToken.balanceOf(alice);
            if (balance > 0) {
                algoToken.sell(bound(amount, 0, balance));
            }
        } else if (action == 2) {
            // Update
            algoToken.update();
        } else {
            // Time travel
            uint256 amount = bound(amounts[i], 3600, 604800); //measured in seconds (range between 1 hour and 1 week)
            vm.warp(block.timestamp + amount);
            vm.roll(block.number + amount / 12); // Assuming 12 seconds per block
        }

        // Test invariants
        bytes16 K = algoToken.K();
        bytes16 Ky = min(K, algoToken.K_target());
        assertTrue(Ky.cmp(algoToken.Ky()) == 0, "Invariant failed: Ky != min(K, K_target)");
        bytes16 Kx = max(algoToken.Ky(), algoToken.K_real());
        assertTrue(Kx.cmp(algoToken.Kx()) == 0, "Invariant failed: Kx != max(Ky, K_real)");

        uint256 peg = algoToken.peg();
        bytes16 f_peg = algoToken.peg().fromUInt();
        assertTrue(
            f_peg.cmp(algoToken.f_peg()) == 0, 
            "Invariant failed: f_peg != algoToken.f_peg()"
        ) ;

        uint256 slip = algoToken.slip();
        bytes16 f_slip = algoToken.slip().fromUInt();
        assertTrue(
            f_slip.cmp(algoToken.f_slip()) == 0, 
            "Invariant failed: f_slip != algoToken.f_slip()"
        ) ;

        bytes16 peg_min = (Kx.mul(f_slip).add(f_peg).div(pow(Ky, f_2)));
        if (f_peg > peg_min) {
            assertTrue(
                algoToken.peg_min_safety().cmp(algoToken.peg_min_drain()) <= 0, 
                "Invariant failed: peg_min_safety > peg_min_drain"
            );
        }

        uint256 hyp_supply = algoToken.hypothetical_supply();
        uint256 circ_supply = algoToken.circ_supply();
        assertTrue(hyp_supply >= circ_supply, "Invariant failed: hypothetical_supply < circ_supply");

        uint256 reserve = peg + slip;
        bytes16 f_reserve = f_peg.add(f_slip);
        assertTrue(f_reserve.cmp(algoToken.f_reserve()) == 0, "Invariant failed: f_reserve != algoToken.f_reserve()");
        assertTrue(reserve == algoToken.reserve(), "Invariant failed: reserve != algoToken.reserve()");

        bytes16 price = algoToken.price();
        if (hyp_supply > 0) {
            assertTrue(
                price.cmp(K.mul(f_reserve).div(hyp_supply.fromUInt())) == 0,
                "Invariant failed: price != K * f_reserve / hyp_supply"
            );
        }


    }

}
}