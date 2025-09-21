// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AlgoToken.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        AlgoToken algoToken = new AlgoToken(
            "AlgoToken",
            "ALGO"
        );
        
        vm.stopBroadcast();
    }
}