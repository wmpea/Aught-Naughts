// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AughtNaughts} from "../src/AughtNaughts.sol";

/// Usage:
///   COLLECTION_NAME="Aught Naughts" COLLECTION_SYMBOL="AUNAU" ROYALTY_BPS=500 \
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --account artist --broadcast
contract Deploy is Script {
    // Canonical mainnet WETH
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        string memory name = vm.envString("COLLECTION_NAME");
        string memory symbol = vm.envString("COLLECTION_SYMBOL");
        uint96 royaltyBps = uint96(vm.envOr("ROYALTY_BPS", uint256(500)));
        address weth = vm.envOr("WETH", MAINNET_WETH);

        vm.startBroadcast();
        AughtNaughts nft = new AughtNaughts(name, symbol, weth, royaltyBps);
        vm.stopBroadcast();

        console.log("AughtNaughts deployed:", address(nft));
        console.log("  name:   ", name);
        console.log("  symbol: ", symbol);
        console.log("  weth:   ", weth);
        console.log("  royalty:", royaltyBps, "bps");
    }
}
