// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AlgoToken.sol";
import "abdk/ABDKMathQuad.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DeployScript is Script {

    using ABDKMathQuad for uint256;
    using ABDKMathQuad for int256;
    using ABDKMathQuad for bytes16;

    ERC20 usdc = ERC20(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes16 k = uint256(1300).fromUInt().div(uint256(1000).fromUInt());
        vm.startBroadcast(deployerPrivateKey);
        
        // AlgoToken algoToken = new AlgoToken(
        //     20e6, // ATH_peg_padding
        //     5.256e6, // bear_current = 2 years
        //     k,
        //     1 * 10**usdc.decimals(),
        //     "Algo Token",
        //     "AT",
        //     "Algo Bond",
        //     "AB",
        //     usdc, //USDC
        //     0x3ffb851eb851eb851eb851eb851eb852,  // bondPortionAtMaturity = 1/e^2
        //     216000 // minimum_block_length_between_bondSum_updates_ = 1 month
        // );

        AlgoToken algoToken = new AlgoToken(
            20e6, // ATH_peg_padding
            5.256e6, // bear_current = 2 years
            k,
            1 * 10**usdc.decimals(),
            "Algo Token",
            "AT",
            usdc, //USDC
            216000 // minimum_block_length_between_bondSum_updates_ = 1 month
        );
        
        vm.stopBroadcast();
    }
}