#!/usr/bin/env bash
# One-command mint pipeline:
#   ./mint.sh <image-file> <name> [description] [mime]
#
# Requires env (or .env sourced below):
#   NFT       - deployed AughtNaughts address
#   RPC_URL   - mainnet RPC endpoint
#   ACCOUNT   - foundry keystore account name (cast wallet import <name> --interactive)
#
# Optional:
#   BATCH_SIZE - chunks per tx (default 2)
#   SENDER     - broadcast sender address (required by recent Foundry versions)
#   SKIP_OPT   - set to 1 to skip lossless optimization

set -euo pipefail

[ -f .env ] && source .env

FILE="${1:?usage: ./mint.sh <image-file> <name> [description] [mime]}"
PIECE_NAME="${2:?usage: ./mint.sh <image-file> <name> [description] [mime]}"
PIECE_DESC="${3:-}"
MIME="${4:-}"

: "${NFT:?set NFT to the deployed contract address}"
: "${RPC_URL:?set RPC_URL}"
: "${ACCOUNT:?set ACCOUNT to your foundry keystore account name}"

# Infer mime from extension if not given
if [ -z "$MIME" ]; then
  case "${FILE##*.}" in
    png) MIME="image/png" ;;
    webp) MIME="image/webp" ;;
    jpg|jpeg) MIME="image/jpeg" ;;
    gif) MIME="image/gif" ;;
    svg) MIME="image/svg+xml" ;;
    *) MIME="application/octet-stream" ;;
  esac
fi

WORK_FILE="$FILE"

# --- Step 1: lossless optimization (pixels bit-identical, fewer bytes) ---
if [ "${SKIP_OPT:-0}" != "1" ] && [ "$MIME" = "image/png" ]; then
  if command -v oxipng >/dev/null 2>&1; then
    WORK_FILE="art/.optimized-$(basename "$FILE")"
    cp "$FILE" "$WORK_FILE"
    BEFORE=$(stat -c%s "$WORK_FILE" 2>/dev/null || stat -f%z "$WORK_FILE")
    oxipng -o max --strip safe --quiet "$WORK_FILE"
    AFTER=$(stat -c%s "$WORK_FILE" 2>/dev/null || stat -f%z "$WORK_FILE")
    echo "oxipng: $BEFORE -> $AFTER bytes ($(( (BEFORE - AFTER) * 100 / BEFORE ))% saved, losslessly)"
  else
    echo "note: oxipng not found — uploading unoptimized PNG (install: cargo install oxipng)"
  fi
fi

SIZE=$(stat -c%s "$WORK_FILE" 2>/dev/null || stat -f%z "$WORK_FILE")
CHUNKS=$(( (SIZE + 24574) / 24575 ))
EST_GAS=$(( SIZE * 250 ))  # rough: ~250 gas/byte all-in
echo ""
echo "Uploading: $WORK_FILE"
echo "  size:      $SIZE bytes ($CHUNKS chunks)"
echo "  est. gas:  ~$EST_GAS (check current base fee: cast base-fee --rpc-url \$RPC_URL)"
echo ""

# --- Step 2: chunk, upload, mint (single broadcast run, multiple txs) ---
NFT="$NFT" FILE="$WORK_FILE" PIECE_NAME="$PIECE_NAME" PIECE_DESC="$PIECE_DESC" \
MIME="$MIME" BATCH_SIZE="${BATCH_SIZE:-2}" \
forge script script/MintPiece.s.sol \
  --rpc-url "$RPC_URL" \
  --account "$ACCOUNT" \
  --broadcast \
  --slow \
  ${SENDER:+--sender "$SENDER"} \
  -vv

echo ""
echo "Done. Verify onchain bytes match your local file:"
echo "  cast call $NFT 'imageData(uint256)(bytes)' <tokenId> --rpc-url \$RPC_URL | cast keccak"
echo "  cast keccak < $WORK_FILE   # should be identical"
