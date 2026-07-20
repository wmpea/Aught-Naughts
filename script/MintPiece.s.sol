// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AughtNaughts} from "../src/AughtNaughts.sol";
import {SSTORE2} from "../src/SSTORE2.sol";

/// Reads an image file, splits it into 24KB SSTORE2 chunks, uploads them in
/// batched transactions, then mints the piece — all in one broadcast run.
///
/// Usage:
///   NFT=0x... FILE=art/piece-001.png PIECE_NAME="Title" PIECE_DESC="..." \
///   MIME="image/png" forge script script/MintPiece.s.sol \
///     --rpc-url $RPC_URL --account artist --broadcast
///
/// Optional: BATCH_SIZE (chunks per tx, default 4 ≈ 25M gas/tx)
contract MintPiece is Script {
    function run() external {
        AughtNaughts nft = AughtNaughts(vm.envAddress("NFT"));
        string memory path = vm.envString("FILE");
        string memory pieceName = vm.envString("PIECE_NAME");
        string memory pieceDesc = vm.envOr("PIECE_DESC", string(""));
        string memory mime = vm.envOr("MIME", string("image/png"));
        uint256 batchSize = vm.envOr("BATCH_SIZE", uint256(2));

        bytes memory data = vm.readFileBinary(path);
        require(data.length > 0, "empty file");

        uint256 chunkSize = SSTORE2.MAX_CHUNK_BYTES;
        uint256 numChunks = (data.length + chunkSize - 1) / chunkSize;

        console.log("File:  ", path);
        console.log("Bytes: ", data.length);
        console.log("Chunks:", numChunks);
        console.log("Txs:   ", (numChunks + batchSize - 1) / batchSize + 1);

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

            address[] memory ptrs = nft.writeChunks(nft.nextTokenId(), batch);
            for (uint256 i = 0; i < n; i++) {
                allPointers[written + i] = ptrs[i];
            }
            written += n;
            console.log("  uploaded chunks:", written, "/", numChunks);
        }

        uint256 tokenId = nft.mint(allPointers, pieceName, pieceDesc, mime);

        vm.stopBroadcast();

        console.log("");
        console.log("Minted tokenId:", tokenId);
        console.log("Verify with: cast call", address(nft));
        console.log('  "imageData(uint256)" and compare keccak to your local file');
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
