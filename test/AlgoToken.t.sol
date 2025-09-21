// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AlgoToken.sol";
import "../src/AlgoBond.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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
    
    address public alice = address(0x1);
    address public bob = address(0x2);
    
    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();
        
        // Deploy AlgoToken with test parameters
        // You'll need to adjust based on your constructor
        algoToken = new AlgoToken(
            "AlgoToken",
            "ALGO"
        );
        
        // Setup test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        
        // Transfer USDC to test accounts
        usdc.transfer(alice, 100000 * 10**6);
        usdc.transfer(bob, 100000 * 10**6);
    }
    
    function testInitialState() public {
        // Add your initial state tests
        assertEq(algoToken.name(), "AlgoToken");
        assertEq(algoToken.symbol(), "ALGO");
    }
}