// SPDX-License-Identifier: MIT

/*
    o====================================================================o

                   ______  __  __  ____    __  __  ______
                  /\  _  \/\ \/\ \/\  _`\ /\ \/\ \/\__  _\
                  \ \ \L\ \ \ \ \ \ \ \L\_\ \ \_\ \/_/\ \/
                   \ \  __ \ \ \ \ \ \ \L_L\ \  _  \ \ \ \
                    \ \ \/\ \ \ \_\ \ \ \/, \ \ \ \ \ \ \ \
                     \ \_\ \_\ \_____\ \____/\ \_\ \_\ \ \_\
                      \/_/\/_/\/_____/\/___/  \/_/\/_/  \/_/

          __  __  ______  __  __  ____    __  __  ______  ____
         /\ \/\ \/\  _  \/\ \/\ \/\  _`\ /\ \/\ \/\__  _\/\  _`\
         \ \ `\\ \ \ \L\ \ \ \ \ \ \ \L\_\ \ \_\ \/_/\ \/\ \,\L\_\
          \ \ , ` \ \  __ \ \ \ \ \ \ \L_L\ \  _  \ \ \ \ \/_\__ \
           \ \ \`\ \ \ \/\ \ \ \_\ \ \ \/, \ \ \ \ \ \ \ \  /\ \L\ \
            \ \_\ \_\ \_\ \_\ \_____\ \____/\ \_\ \_\ \ \_\ \ `\____\
             \/_/\/_/\/_/\/_/\/_____/\/___/  \/_/\/_/  \/_/  \/_____/

      · 0 · 0 · 0 · 0 · 0 · 0 · 0 · 0 · 0 · 0 · 0 · 0 · 0 · 0 · 0 · 0 ·

             1/1s with images, metadata, & auctions fully onchain
                               thanks Ethereum

    o====================================================================o
*/

pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "openzeppelin-contracts/contracts/token/common/ERC2981.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {SSTORE2} from "./SSTORE2.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

/// @title AughtNaughts
/// @notice A self-contained 1/1 art practice on Ethereum:
///         - Owner-curated ERC-721 mints
///         - Image bytes stored fully onchain via SSTORE2 chunks (immutable at mint)
///         - Optional append-once hi-res companion data per token (frozen on set)
///         - Embedded reserve auction (Nouns-hardened: anti-snipe buffer, min
///           increment, ETH refund with WETH fallback, reentrancy guards)
///         - ERC-2981 royalties
/// @dev The canonical image is set at mint and can never change. Hi-res data
///      may be attached exactly once by the owner and is then permanent.
contract AughtNaughts is ERC721, ERC2981, Ownable, ReentrancyGuard {
    using Strings for uint256;

    // ---------------------------------------------------------------------
    // Pieces
    // ---------------------------------------------------------------------

    struct Piece {
        address[] pointers;      // SSTORE2 chunk pointers — canonical image (immutable)
        address[] hiResPointers; // optional companion data — append-once, then frozen
        string name;
        string description;
        string mimeType;         // e.g. "image/png", "image/webp"
    }

    mapping(uint256 => Piece) private _pieces;
    uint256 public nextTokenId = 1;

    // ---------------------------------------------------------------------
    // Auctions
    // ---------------------------------------------------------------------

    struct Auction {
        uint96 amount;        // current highest bid
        uint96 reservePrice;
        uint40 startTime;
        uint40 endTime;
        address bidder;       // current highest bidder (address(0) = no bids)
        bool settled;
    }

    /// @notice tokenId => auction state. startTime == 0 means never auctioned.
    mapping(uint256 => Auction) public auctions;

    /// @notice A bid inside this window extends the auction to now + timeBuffer.
    uint40 public timeBuffer = 5 minutes;

    /// @notice Each bid must exceed the last by this percentage.
    uint8 public minBidIncrementPercentage = 5;

    /// @notice WETH, used as a refund fallback for bidders that reject ETH.
    address public immutable weth;

    // ---------------------------------------------------------------------
    // Events / errors
    // ---------------------------------------------------------------------

    event ChunkWritten(uint256 indexed batchId, uint256 index, address pointer, uint256 size);
    event PieceMinted(uint256 indexed tokenId, uint256 chunkCount, uint256 byteSize);
    event HiResSet(uint256 indexed tokenId, uint256 chunkCount, uint256 byteSize);
    event AuctionStarted(uint256 indexed tokenId, uint256 reservePrice, uint256 startTime, uint256 endTime);
    event AuctionBid(uint256 indexed tokenId, address indexed bidder, uint256 amount, bool extended);
    event AuctionExtended(uint256 indexed tokenId, uint256 endTime);
    event AuctionSettled(uint256 indexed tokenId, address indexed winner, uint256 amount);
    event AuctionCanceled(uint256 indexed tokenId);
    event TimeBufferUpdated(uint40 timeBuffer);
    event MinBidIncrementUpdated(uint8 percentage);

    error NoPointers();
    error EmptyChunk();
    error NonexistentToken();
    error HiResAlreadySet();
    error TokenNotHeldByOwner();
    error AuctionAlreadyActive();
    error AuctionNotActive();
    error AuctionExpired();
    error AuctionNotEnded();
    error AuctionAlreadySettled();
    error AuctionHasBids();
    error BidBelowReserve();
    error BidIncrementTooLow();
    error ZeroDuration();

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @param name_        Collection name (e.g. "Your Series Title")
    /// @param symbol_      Collection symbol
    /// @param weth_        Canonical WETH address for the target chain
    /// @param royaltyBps   Default royalty in basis points (e.g. 500 = 5%)
    constructor(
        string memory name_,
        string memory symbol_,
        address weth_,
        uint96 royaltyBps
    ) ERC721(name_, symbol_) Ownable(msg.sender) {
        weth = weth_;
        _setDefaultRoyalty(msg.sender, royaltyBps);
    }

    // ---------------------------------------------------------------------
    // Storage pipeline (owner)
    // ---------------------------------------------------------------------

    /// @notice Deploys raw data chunks as SSTORE2 contracts. Called in batches
    ///         by the mint pipeline; returned pointers are later passed to
    ///         `mint` or `setHiResData`.
    /// @param batchId Arbitrary correlation id echoed in events (e.g. piece number).
    function writeChunks(uint256 batchId, bytes[] calldata chunks)
        external
        onlyOwner
        returns (address[] memory pointers)
    {
        pointers = new address[](chunks.length);
        for (uint256 i = 0; i < chunks.length; i++) {
            if (chunks[i].length == 0) revert EmptyChunk();
            pointers[i] = SSTORE2.write(chunks[i]);
            emit ChunkWritten(batchId, i, pointers[i], chunks[i].length);
        }
    }

    /// @notice Mints a new 1/1 to the owner. The image (the concatenation of
    ///         the chunk payloads, in order) is immutable from this point on.
    function mint(
        address[] calldata pointers,
        string calldata pieceName,
        string calldata description,
        string calldata mimeType
    ) external onlyOwner returns (uint256 tokenId) {
        if (pointers.length == 0) revert NoPointers();
        uint256 byteSize = SSTORE2.totalSize(pointers); // reverts on invalid pointer

        tokenId = nextTokenId++;
        Piece storage p = _pieces[tokenId];
        p.pointers = pointers;
        p.name = pieceName;
        p.description = description;
        p.mimeType = bytes(mimeType).length == 0 ? "image/png" : mimeType;

        _safeMint(msg.sender, tokenId);
        emit PieceMinted(tokenId, pointers.length, byteSize);
    }

    /// @notice Attaches hi-res companion data to a token. May be called exactly
    ///         once per token; the data is then permanent. The canonical image
    ///         set at mint is never affected.
    function setHiResData(uint256 tokenId, address[] calldata pointers) external onlyOwner {
        _requireOwned(tokenId);
        Piece storage p = _pieces[tokenId];
        if (p.hiResPointers.length != 0) revert HiResAlreadySet();
        if (pointers.length == 0) revert NoPointers();
        uint256 byteSize = SSTORE2.totalSize(pointers);

        p.hiResPointers = pointers;
        emit HiResSet(tokenId, pointers.length, byteSize);
    }

    // ---------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------

    /// @notice Raw canonical image bytes (concatenated chunks).
    function imageData(uint256 tokenId) public view returns (bytes memory) {
        _requireOwned(tokenId);
        return SSTORE2.readAll(_pieces[tokenId].pointers);
    }

    /// @notice Raw hi-res companion bytes. Reverts if none set.
    function hiResData(uint256 tokenId) external view returns (bytes memory) {
        _requireOwned(tokenId);
        address[] memory ptrs = _pieces[tokenId].hiResPointers;
        if (ptrs.length == 0) revert NoPointers();
        return SSTORE2.readAll(ptrs);
    }

    /// @notice Chunk pointer addresses for offchain reconstruction with cheap
    ///         per-chunk `eth_getCode` calls (no eth_call gas limits involved).
    function imagePointers(uint256 tokenId) external view returns (address[] memory) {
        _requireOwned(tokenId);
        return _pieces[tokenId].pointers;
    }

    function hiResPointers(uint256 tokenId) external view returns (address[] memory) {
        _requireOwned(tokenId);
        return _pieces[tokenId].hiResPointers;
    }

    function pieceInfo(uint256 tokenId)
        external
        view
        returns (string memory pieceName, string memory description, string memory mimeType, uint256 chunkCount, bool hasHiRes)
    {
        _requireOwned(tokenId);
        Piece storage p = _pieces[tokenId];
        return (p.name, p.description, p.mimeType, p.pointers.length, p.hiResPointers.length != 0);
    }

    /// @notice Fully onchain metadata: UTF-8 JSON data URI with a base64 image
    ///         data URI inside. Universally supported by marketplaces/wallets.
    /// @dev For multi-MB pieces this view call is gas-heavy (memory expansion +
    ///      base64). Use an RPC with a generous eth_call gas cap, or reconstruct
    ///      via `imagePointers` + eth_getCode.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return string(abi.encodePacked("data:application/json;utf8,", tokenJSON(tokenId)));
    }

    /// @notice Raw metadata JSON (no data-URI wrapper). This is the resolution
    ///         target for ERC-4804 web3:// clients and any frontend that wants
    ///         the clean raw-JSON path, e.g.:
    ///         web3://<this contract>/tokenJSON/<tokenId>?returns=(string)
    function tokenJSON(uint256 tokenId) public view returns (string memory) {
        _requireOwned(tokenId);
        Piece storage p = _pieces[tokenId];

        return string(
            abi.encodePacked(
                '{"name":"',
                _escapeJSON(p.name),
                '","description":"',
                _escapeJSON(p.description),
                '","image":"data:',
                p.mimeType,
                ";base64,",
                Base64.encode(SSTORE2.readAll(p.pointers)),
                '"}'
            )
        );
    }

    // ---------------------------------------------------------------------
    // Auction (owner controls lifecycle; anyone can bid/settle)
    // ---------------------------------------------------------------------

    /// @notice Escrows the token in the contract and opens a reserve auction.
    function startAuction(uint256 tokenId, uint96 reservePrice, uint40 duration)
        external
        onlyOwner
        nonReentrant
    {
        if (duration == 0) revert ZeroDuration();
        if (ownerOf(tokenId) != owner()) revert TokenNotHeldByOwner();
        Auction storage a = auctions[tokenId];
        if (a.startTime != 0 && !a.settled) revert AuctionAlreadyActive();

        uint40 start = uint40(block.timestamp);
        auctions[tokenId] = Auction({
            amount: 0,
            reservePrice: reservePrice,
            startTime: start,
            endTime: start + duration,
            bidder: address(0),
            settled: false
        });

        _transfer(owner(), address(this), tokenId);
        emit AuctionStarted(tokenId, reservePrice, start, start + duration);
    }

    /// @notice Places a bid. Refunds the previous bidder; a refund can never
    ///         block the auction (ETH send with gas cap, WETH fallback).
    function createBid(uint256 tokenId) external payable nonReentrant {
        Auction storage a = auctions[tokenId];
        if (a.startTime == 0 || a.settled) revert AuctionNotActive();
        if (block.timestamp >= a.endTime) revert AuctionExpired();
        if (msg.value < a.reservePrice) revert BidBelowReserve();
        if (msg.value < a.amount + (uint256(a.amount) * minBidIncrementPercentage) / 100 || msg.value <= a.amount) {
            revert BidIncrementTooLow();
        }

        address lastBidder = a.bidder;
        uint256 lastAmount = a.amount;

        a.amount = uint96(msg.value);
        a.bidder = msg.sender;

        // Anti-snipe: extend if bid lands inside the buffer window.
        bool extended = a.endTime - block.timestamp < timeBuffer;
        if (extended) {
            a.endTime = uint40(block.timestamp) + timeBuffer;
            emit AuctionExtended(tokenId, a.endTime);
        }

        if (lastBidder != address(0)) {
            _safeTransferETHWithFallback(lastBidder, lastAmount);
        }

        emit AuctionBid(tokenId, msg.sender, msg.value, extended);
    }

    /// @notice Settles an ended auction: token to winner, proceeds to owner.
    ///         With no bids, the token returns to the owner. Callable by anyone.
    function settleAuction(uint256 tokenId) external nonReentrant {
        Auction storage a = auctions[tokenId];
        if (a.startTime == 0) revert AuctionNotActive();
        if (a.settled) revert AuctionAlreadySettled();
        if (block.timestamp < a.endTime) revert AuctionNotEnded();

        a.settled = true;

        if (a.bidder == address(0)) {
            _transfer(address(this), owner(), tokenId);
            emit AuctionSettled(tokenId, address(0), 0);
        } else {
            // Deliberate unsafe transfer (no onERC721Received check): a winner
            // contract that cannot receive ERC-721s must not be able to jam
            // settlement. Same reasoning as Nouns' transferFrom on settle.
            _transfer(address(this), a.bidder, tokenId);
            _safeTransferETHWithFallback(owner(), a.amount);
            emit AuctionSettled(tokenId, a.bidder, a.amount);
        }
    }

    /// @notice Cancels an auction that has received no bids; token returns home.
    function cancelAuction(uint256 tokenId) external onlyOwner nonReentrant {
        Auction storage a = auctions[tokenId];
        if (a.startTime == 0 || a.settled) revert AuctionNotActive();
        if (a.bidder != address(0)) revert AuctionHasBids();

        a.settled = true;
        _transfer(address(this), owner(), tokenId);
        emit AuctionCanceled(tokenId);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setTimeBuffer(uint40 newTimeBuffer) external onlyOwner {
        timeBuffer = newTimeBuffer;
        emit TimeBufferUpdated(newTimeBuffer);
    }

    function setMinBidIncrementPercentage(uint8 newPercentage) external onlyOwner {
        minBidIncrementPercentage = newPercentage;
        emit MinBidIncrementUpdated(newPercentage);
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Nouns pattern: try a gas-capped ETH send; on failure, wrap to WETH
    ///      and transfer that. Refunds and payouts can therefore never revert.
    function _safeTransferETHWithFallback(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount, gas: 30_000}("");
        if (!success) {
            IWETH(weth).deposit{value: amount}();
            IWETH(weth).transfer(to, amount);
        }
    }

    /// @dev Minimal JSON string escaping for name/description fields.
    function _escapeJSON(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra = 0;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\" || c == 0x0A || c == 0x0D || c == 0x09) extra++;
        }
        if (extra == 0) return s;

        bytes memory out = new bytes(b.length + extra);
        uint256 j = 0;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"') {
                out[j++] = "\\";
                out[j++] = '"';
            } else if (c == "\\") {
                out[j++] = "\\";
                out[j++] = "\\";
            } else if (c == 0x0A) {
                out[j++] = "\\";
                out[j++] = "n";
            } else if (c == 0x0D) {
                out[j++] = "\\";
                out[j++] = "r";
            } else if (c == 0x09) {
                out[j++] = "\\";
                out[j++] = "t";
            } else {
                out[j++] = c;
            }
        }
        return string(out);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
