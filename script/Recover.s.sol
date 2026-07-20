// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AughtNaughts} from "../src/AughtNaughts.sol";
import {SSTORE2} from "../src/SSTORE2.sol";

contract Recover is Script {
    uint256 constant CHUNK = 24575;

    AughtNaughts nft;
    address[] pointers;
    uint256[] missingIdx;

    function run() external {
        nft = AughtNaughts(vm.envAddress("NFT"));
        bytes memory data = vm.readFileBinary(vm.envString("FILE"));

        _loadRecovery(data.length);
        console.log("slices total:    ", pointers.length);
        console.log("already onchain: ", pointers.length - missingIdx.length);
        console.log("to upload now:   ", missingIdx.length);

        vm.startBroadcast();
        _uploadMissing(data);

        require(SSTORE2.totalSize(pointers) == data.length, "size mismatch - do not mint");
        require(
            keccak256(SSTORE2.readAll(pointers)) == keccak256(data),
            "content mismatch - do not mint"
        );
        console.log("onchain bytes == local file: verified");

        uint256 tokenId = nft.mint(
            pointers,
            vm.envString("PIECE_NAME"),
            vm.envOr("PIECE_DESC", string("")),
            vm.envOr("MIME", string("image/png"))
        );
        vm.stopBroadcast();

        console.log("Minted tokenId:", tokenId);
    }

    function _loadRecovery(uint256 fileLen) internal {
        string memory json = vm.readFile("recovery.json");
        string[] memory ptrStrs = vm.parseJsonStringArray(json, ".ordered_pointers");
        uint256 n = (fileLen + CHUNK - 1) / CHUNK;
        require(ptrStrs.length == n, "recovery.json slice count != file slice count");

        for (uint256 i = 0; i < n; i++) {
            if (keccak256(bytes(ptrStrs[i])) == keccak256("MISSING")) {
                pointers.push(address(0));
                missingIdx.push(i);
            } else {
                pointers.push(vm.parseAddress(ptrStrs[i]));
            }
        }
    }

    function _uploadMissing(bytes memory data) internal {
        uint256 done = 0;
        while (done < missingIdx.length) {
            uint256 batch = missingIdx.length - done;
            if (batch > 2) batch = 2;

            bytes[] memory chunks = new bytes[](batch);
            for (uint256 j = 0; j < batch; j++) {
                chunks[j] = _slice(data, missingIdx[done + j]);
            }
            address[] memory newPtrs = nft.writeChunks(nft.nextTokenId(), chunks);
            for (uint256 j = 0; j < batch; j++) {
                pointers[missingIdx[done + j]] = newPtrs[j];
            }
            done += batch;
            console.log("  uploaded missing chunks:", done, "/", missingIdx.length);
        }
    }

    function _slice(bytes memory data, uint256 sliceIndex) internal pure returns (bytes memory out) {
        uint256 start = sliceIndex * CHUNK;
        uint256 end = start + CHUNK;
        if (end > data.length) end = data.length;
        out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[start + i];
        }
    }
}
