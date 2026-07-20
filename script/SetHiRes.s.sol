// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AughtNaughts} from "../src/AughtNaughts.sol";
import {SSTORE2} from "../src/SSTORE2.sol";

/// Attaches the one-time hi-res companion data to an existing token.
/// PERMANENT once set — the contract enforces append-once.
///
/// Usage:
///   NFT=0x... TOKEN_ID=1 FILE=art/piece-001-hires.png \
///   forge script script/SetHiRes.s.sol --rpc-url $RPC_URL --account artist --broadcast
contract SetHiRes is Script {
    function run() external {
        AughtNaughts nft = AughtNaughts(vm.envAddress("NFT"));
        uint256 tokenId = vm.envUint("TOKEN_ID");
        string memory path = vm.envString("FILE");
        uint256 batchSize = vm.envOr("BATCH_SIZE", uint256(2));

        bytes memory data = vm.readFileBinary(path);
        require(data.length > 0, "empty file");

        uint256 chunkSize = SSTORE2.MAX_CHUNK_BYTES;
        uint256 numChunks = (data.length + chunkSize - 1) / chunkSize;
        console.log("Hi-res bytes:", data.length, "chunks:", numChunks);

        address[] memory allPointers = new address[](numChunks);
        uint256 written = 0;

        vm.startBroadcast();

        while (written < numChunks) {
            uint256 n = numChunks - written;
            if (n > batchSize) n = batchSize;

            bytes[] memory batch = new bytes[](n);
            for (uint256 i = 0; i < n; i++) {
                uint256 start = (written + i) * chunkSize;
                uint256 end = start + chunkSize;
                if (end > data.length) end = data.length;
                batch[i] = _slice(data, start, end);
            }

            address[] memory ptrs = nft.writeChunks(tokenId, batch);
            for (uint256 i = 0; i < n; i++) {
                allPointers[written + i] = ptrs[i];
            }
            written += n;
            console.log("  uploaded chunks:", written, "/", numChunks);
        }

        nft.setHiResData(tokenId, allPointers);
        vm.stopBroadcast();

        console.log("Hi-res data permanently attached to token", tokenId);
    }

    function _slice(bytes memory data, uint256 start, uint256 end)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[start + i];
        }
    }
}
