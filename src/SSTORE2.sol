// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read/write persistent data as contract bytecode.
/// @dev Data is deployed behind a single STOP (0x00) prefix byte so the
///      "data contract" can never be executed or selfdestructed.
///      Pattern originated by 0xSequence / Solmate; minimal vendored version.
library SSTORE2 {
    /// @dev EIP-170 code size limit (24_576) minus the 1-byte STOP prefix.
    uint256 internal constant MAX_CHUNK_BYTES = 24_575;

    error DataTooLarge();
    error WriteFailed();
    error InvalidPointer();

    /// @notice Deploys `data` as the code of a new contract, returns its address.
    function write(bytes memory data) internal returns (address pointer) {
        if (data.length > MAX_CHUNK_BYTES) revert DataTooLarge();

        // Init code:
        //   0x61 <len (2 bytes)>  PUSH2 len         | len
        //   0x80                  DUP1              | len len
        //   0x60 0x0A             PUSH1 0x0A        | 10 len len
        //   0x3D                  RETURNDATASIZE(0) | 0 10 len len
        //   0x39                  CODECOPY          | len   (mem[0..len] = code[10..10+len])
        //   0x3D                  RETURNDATASIZE(0) | 0 len
        //   0xF3                  RETURN
        // followed by: 0x00 (STOP prefix) ++ data
        bytes memory initCode = abi.encodePacked(
            hex"61",
            uint16(data.length + 1),
            hex"80600A3D393DF3",
            hex"00",
            data
        );

        assembly {
            pointer := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (pointer == address(0)) revert WriteFailed();
    }

    /// @notice Reads the full data payload stored at `pointer`.
    function read(address pointer) internal view returns (bytes memory data) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(pointer)
        }
        if (codeSize == 0) revert InvalidPointer();

        uint256 size = codeSize - 1; // skip STOP prefix
        data = new bytes(size);
        assembly {
            extcodecopy(pointer, add(data, 0x20), 1, size)
        }
    }

    /// @notice Sum of payload sizes across `pointers`.
    function totalSize(address[] memory pointers) internal view returns (uint256 size) {
        for (uint256 i = 0; i < pointers.length; i++) {
            uint256 codeSize;
            address p = pointers[i];
            assembly {
                codeSize := extcodesize(p)
            }
            if (codeSize == 0) revert InvalidPointer();
            size += codeSize - 1;
        }
    }

    /// @notice Concatenates the payloads of all `pointers` into one buffer.
    function readAll(address[] memory pointers) internal view returns (bytes memory data) {
        data = new bytes(totalSize(pointers));
        uint256 offset = 0x20;
        for (uint256 i = 0; i < pointers.length; i++) {
            address p = pointers[i];
            uint256 codeSize;
            assembly {
                codeSize := extcodesize(p)
            }
            uint256 size = codeSize - 1;
            assembly {
                extcodecopy(p, add(data, offset), 1, size)
            }
            offset += size;
        }
    }
}
