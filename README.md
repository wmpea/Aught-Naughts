# Aught Naughts

Aught Naughts is a fully onchain 1/1 art practice on Ethereum. Each piece is an
ERC-721 token whose image, metadata, and primary auction live entirely in the
contract. The system has no external dependencies.

- Contract: [`0x6Df21fb1bf29F24A589289b8cb4CF614aAe56893`](https://etherscan.io/address/0x6Df21fb1bf29F24A589289b8cb4CF614aAe56893#code) (Ethereum mainnet, verified)
- Collection: [OpenSea](https://opensea.io/assets/ethereum/0x6Df21fb1bf29F24A589289b8cb4CF614aAe56893/1)
- Live auction page: [wmpea.github.io/portfolio](https://wmpea.github.io/portfolio/#aughtnaughts)
- Artist: [aughtnaughts.wmp.eth](https://app.ens.domains/aughtnaughts.wmp.eth)

## How it works

**Storage.** Image bytes are deployed as contract bytecode in 24 KB chunks
(the SSTORE2 pattern). `mint` records the ordered chunk pointers, a title, a
description, and a MIME type. The canonical image is immutable from the moment
of mint.

**Metadata.** `tokenURI` assembles a UTF-8 JSON data URI with a base64 image
data URI inside, entirely onchain. `tokenJSON` returns the same JSON without
the data-URI wrapper, for ERC-4804 `web3://` clients. For multi-megabyte
pieces, `tokenURI` is a heavy view call; RPC providers with low `eth_call` gas
caps can reconstruct any piece from `imagePointers` and `eth_getCode` instead.

**Hi-res layer.** `setHiResData` attaches an optional high-resolution
companion to a token exactly once. After it is set, the data is frozen. The
canonical image is never affected.

**Auctions.** Each token can be auctioned by the owner through an embedded
reserve auction that follows the Nouns auction house pattern: a minimum bid
increment, an anti-snipe time buffer that extends the auction when a bid lands
near the end, and outbid refunds sent as a gas-capped ETH transfer with a WETH
fallback, so a refund can never block the auction. Settlement is
permissionless. State updates follow checks-effects-interactions ordering.

**Royalties.** ERC-2981, adjustable by the owner.

## Repository layout

```
src/AughtNaughts.sol      Main contract: ERC-721, storage, auction, royalties
src/SSTORE2.sol           Chunked bytecode storage primitive
script/Deploy.s.sol       Deployment
script/MintPiece.s.sol    Chunks a file, uploads in batched transactions, mints
script/SetHiRes.s.sol     One-time hi-res attachment
script/Recover.s.sol      Finishes an interrupted upload; verifies bytes before minting
test/AughtNaughts.t.sol   Test suite (21 tests, including griefing scenarios)
mint.sh                   One-command mint pipeline
auction.sh                Auction management: start, status, bid, settle, cancel
```

## Getting started

Requires [Foundry](https://getfoundry.sh).

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-git
forge install foundry-rs/forge-std --no-git
forge test
```

Configuration goes in `.env` (never committed):

```
RPC_URL=<your RPC endpoint>
ACCOUNT=<foundry keystore account name>
SENDER=<the account's address>
NFT=<deployed contract address>
ETHERSCAN_API_KEY=<for verification>
```

## Minting

```bash
./mint.sh art/piece.png "Title" "Description"
```

The pipeline optimizes the PNG losslessly with oxipng if it is installed,
splits the result into 24 KB chunks, uploads them in batched transactions with
`--slow` sequencing, and mints. Verify any piece against a local file by
comparing hashes of `imageData(tokenId)` and the file.

At mainnet gas prices near 0.1 gwei, storing a 1.6 MB piece costs roughly
0.02 ETH. Storage cost scales at about 250M gas per MB.

## Auctions

```bash
./auction.sh start <tokenId> <reserveEth> <durationHours>
./auction.sh status <tokenId>
./auction.sh bid <tokenId> <amountEth>
./auction.sh settle <tokenId>
./auction.sh cancel <tokenId>      # owner, zero-bid auctions only
```

## Security

- Independent review: [bytecode-level audit, July 2026](https://leftclaw.services/result/442.html).
  The audit confirmed the refund path, WETH fallback, checks-effects-interactions
  ordering, and royalty bounds. Both scored findings concern owner privileges,
  which are inherent to a single-artist practice; the auction timing finding
  reflects a bytecode misread of the global parameter setters, which cannot
  modify a live auction's end time.
- Custody: the contract is operated by a single artist-controlled key. Auction
  parameters (time buffer, minimum increment) do not change while an auction
  is live.
- The canonical image for a minted token cannot be modified by anyone,
  including the owner.

## License

Code is released under the [MIT License](LICENSE). Artwork is not covered by
this license.
