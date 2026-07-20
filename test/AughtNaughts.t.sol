// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AughtNaughts} from "../src/AughtNaughts.sol";
import {SSTORE2} from "../src/SSTORE2.sol";

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }
}

/// @dev A bidder that rejects all ETH — tries to jam refunds/settlement.
contract RevertingBidder {
    AughtNaughts immutable nft;

    constructor(AughtNaughts _nft) {
        nft = _nft;
    }

    function bid(uint256 tokenId) external payable {
        nft.createBid{value: msg.value}(tokenId);
    }

    receive() external payable {
        revert("no ETH accepted");
    }
}

contract AughtNaughtsTest is Test {
    AughtNaughts nft;
    MockWETH weth;

    address artist = makeAddr("artist");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes sampleImage;

    function setUp() public {
        weth = new MockWETH();
        vm.prank(artist);
        nft = new AughtNaughts("Test Series", "T1OF1", address(weth), 500);

        // ~60KB pseudo-image => 3 chunks
        sampleImage = new bytes(60_000);
        for (uint256 i = 0; i < sampleImage.length; i++) {
            sampleImage[i] = bytes1(uint8(i % 251));
        }

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _chunk(bytes memory data) internal pure returns (bytes[] memory chunks) {
        uint256 n = (data.length + SSTORE2.MAX_CHUNK_BYTES - 1) / SSTORE2.MAX_CHUNK_BYTES;
        chunks = new bytes[](n);
        uint256 offset = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 len = data.length - offset;
            if (len > SSTORE2.MAX_CHUNK_BYTES) len = SSTORE2.MAX_CHUNK_BYTES;
            bytes memory c = new bytes(len);
            for (uint256 j = 0; j < len; j++) {
                c[j] = data[offset + j];
            }
            chunks[i] = c;
            offset += len;
        }
    }

    function _mintPiece() internal returns (uint256 tokenId) {
        vm.startPrank(artist);
        address[] memory ptrs = nft.writeChunks(1, _chunk(sampleImage));
        tokenId = nft.mint(ptrs, "Piece One", "First curated output", "image/png");
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Storage & metadata
    // -----------------------------------------------------------------

    function test_MintStoresImageExactly() public {
        uint256 tokenId = _mintPiece();
        assertEq(nft.ownerOf(tokenId), artist);
        assertEq(keccak256(nft.imageData(tokenId)), keccak256(sampleImage));

        (string memory pieceName,,, uint256 chunkCount, bool hasHiRes) = nft.pieceInfo(tokenId);
        assertEq(pieceName, "Piece One");
        assertEq(chunkCount, 3);
        assertFalse(hasHiRes);
    }

    function test_ChunkRoundtripFuzz(bytes calldata data) public {
        vm.assume(data.length > 0 && data.length <= 50_000);
        vm.startPrank(artist);
        address[] memory ptrs = nft.writeChunks(9, _chunk(data));
        uint256 tokenId = nft.mint(ptrs, "Fuzz", "fuzzed", "image/webp");
        vm.stopPrank();
        assertEq(keccak256(nft.imageData(tokenId)), keccak256(data));
    }

    function test_TokenURIStructure() public {
        uint256 tokenId = _mintPiece();
        string memory uri = nft.tokenURI(tokenId);
        assertTrue(vm.contains(uri, 'data:application/json;utf8,{"name":"Piece One"'));
        assertTrue(vm.contains(uri, '"image":"data:image/png;base64,'));
    }

    function test_TokenJSONIsRawAndConsistentWithTokenURI() public {
        uint256 tokenId = _mintPiece();
        string memory json = nft.tokenJSON(tokenId);
        string memory uri = nft.tokenURI(tokenId);

        // raw JSON: starts with '{', no data-URI wrapper
        assertEq(bytes(json)[0], "{");
        assertTrue(vm.contains(json, '"name":"Piece One"'));
        // tokenURI is exactly the data-URI wrapper around the same JSON
        assertEq(uri, string(abi.encodePacked("data:application/json;utf8,", json)));
    }

    function test_TokenURIEscapesJSON() public {
        vm.startPrank(artist);
        address[] memory ptrs = nft.writeChunks(1, _chunk(hex"01"));
        uint256 tokenId = nft.mint(ptrs, 'He said "hi"', "line1\nline2", "");
        vm.stopPrank();
        string memory uri = nft.tokenURI(tokenId);
        assertTrue(vm.contains(uri, '\\"hi\\"'));
        assertTrue(vm.contains(uri, "line1\\nline2"));
    }

    function test_OnlyOwnerCanMintAndWrite() public {
        bytes[] memory chunks = _chunk(sampleImage);
        vm.prank(alice);
        vm.expectRevert();
        nft.writeChunks(1, chunks);

        address[] memory ptrs = new address[](1);
        vm.prank(alice);
        vm.expectRevert();
        nft.mint(ptrs, "x", "y", "");
    }

    // -----------------------------------------------------------------
    // Hi-res: append-once, then frozen
    // -----------------------------------------------------------------

    function test_HiResAppendOnce() public {
        uint256 tokenId = _mintPiece();
        bytes memory hiRes = new bytes(30_000);
        hiRes[0] = 0xAB;

        vm.startPrank(artist);
        address[] memory ptrs = nft.writeChunks(2, _chunk(hiRes));
        nft.setHiResData(tokenId, ptrs);

        assertEq(keccak256(nft.hiResData(tokenId)), keccak256(hiRes));
        // canonical image untouched
        assertEq(keccak256(nft.imageData(tokenId)), keccak256(sampleImage));

        // second attempt: frozen forever
        vm.expectRevert(AughtNaughts.HiResAlreadySet.selector);
        nft.setHiResData(tokenId, ptrs);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Auction lifecycle
    // -----------------------------------------------------------------

    function test_StartAuctionEscrowsToken() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);
        assertEq(nft.ownerOf(tokenId), address(nft));
    }

    function test_BidBelowReserveReverts() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);

        vm.prank(alice);
        vm.expectRevert(AughtNaughts.BidBelowReserve.selector);
        nft.createBid{value: 0.5 ether}(tokenId);
    }

    function test_BidIncrementEnforced() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);

        vm.prank(alice);
        nft.createBid{value: 1 ether}(tokenId);

        // 5% min increment => 1.05 required
        vm.prank(bob);
        vm.expectRevert(AughtNaughts.BidIncrementTooLow.selector);
        nft.createBid{value: 1.04 ether}(tokenId);

        vm.prank(bob);
        nft.createBid{value: 1.05 ether}(tokenId);
    }

    function test_OutbidRefundsPreviousBidder() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        nft.createBid{value: 1 ether}(tokenId);
        assertEq(alice.balance, aliceBefore - 1 ether);

        vm.prank(bob);
        nft.createBid{value: 2 ether}(tokenId);
        assertEq(alice.balance, aliceBefore); // refunded in full
    }

    function test_AntiSnipeExtends() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);
        (,,, uint40 endTime,,) = nft.auctions(tokenId);

        // land a bid 1 minute before close
        vm.warp(endTime - 1 minutes);
        vm.prank(alice);
        nft.createBid{value: 1 ether}(tokenId);

        (,,, uint40 newEnd,,) = nft.auctions(tokenId);
        assertEq(newEnd, block.timestamp + nft.timeBuffer());
        assertGt(newEnd, endTime);
    }

    function test_SettleTransfersTokenAndProceeds() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);

        vm.prank(alice);
        nft.createBid{value: 3 ether}(tokenId);

        vm.expectRevert(AughtNaughts.AuctionNotEnded.selector);
        nft.settleAuction(tokenId);

        vm.warp(block.timestamp + 24 hours + 1);
        uint256 artistBefore = artist.balance;
        nft.settleAuction(tokenId); // anyone can settle

        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(artist.balance, artistBefore + 3 ether);
        assertEq(address(nft).balance, 0);

        vm.expectRevert(AughtNaughts.AuctionAlreadySettled.selector);
        nft.settleAuction(tokenId);
    }

    function test_NoBidSettleReturnsToken() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);

        vm.warp(block.timestamp + 24 hours + 1);
        nft.settleAuction(tokenId);
        assertEq(nft.ownerOf(tokenId), artist);
    }

    function test_ReauctionAfterSettle() public {
        uint256 tokenId = _mintPiece();
        vm.startPrank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        nft.settleAuction(tokenId);
        // no bids -> back home; can run it again
        nft.startAuction(tokenId, 0.5 ether, 12 hours);
        vm.stopPrank();
        assertEq(nft.ownerOf(tokenId), address(nft));
    }

    function test_CancelOnlyWithoutBids() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);

        vm.prank(alice);
        nft.createBid{value: 1 ether}(tokenId);

        vm.prank(artist);
        vm.expectRevert(AughtNaughts.AuctionHasBids.selector);
        nft.cancelAuction(tokenId);
    }

    function test_CancelReturnsToken() public {
        uint256 tokenId = _mintPiece();
        vm.startPrank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);
        nft.cancelAuction(tokenId);
        vm.stopPrank();
        assertEq(nft.ownerOf(tokenId), artist);
    }

    function test_BidAfterEndReverts() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(alice);
        vm.expectRevert(AughtNaughts.AuctionExpired.selector);
        nft.createBid{value: 1 ether}(tokenId);
    }

    // -----------------------------------------------------------------
    // Griefing resistance
    // -----------------------------------------------------------------

    function test_RevertingBidderCannotJamAuction() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);

        RevertingBidder griefer = new RevertingBidder(nft);
        vm.deal(address(griefer), 10 ether);
        griefer.bid{value: 1 ether}(tokenId);

        // outbidding the griefer must succeed; refund lands as WETH
        vm.prank(alice);
        nft.createBid{value: 2 ether}(tokenId);
        assertEq(weth.balanceOf(address(griefer)), 1 ether);

        (,,,, address bidder,) = nft.auctions(tokenId);
        assertEq(bidder, alice);
    }

    function test_RevertingWinnerCannotJamSettlement() public {
        uint256 tokenId = _mintPiece();
        vm.prank(artist);
        nft.startAuction(tokenId, 1 ether, 24 hours);

        RevertingBidder griefer = new RevertingBidder(nft);
        vm.deal(address(griefer), 10 ether);
        griefer.bid{value: 1 ether}(tokenId);

        vm.warp(block.timestamp + 24 hours + 1);
        nft.settleAuction(tokenId); // must not revert
        assertEq(nft.ownerOf(tokenId), address(griefer));
    }

    // -----------------------------------------------------------------
    // Royalties
    // -----------------------------------------------------------------

    function test_RoyaltyInfo() public {
        uint256 tokenId = _mintPiece();
        (address receiver, uint256 amount) = nft.royaltyInfo(tokenId, 10 ether);
        assertEq(receiver, artist);
        assertEq(amount, 0.5 ether); // 500 bps
    }
}
