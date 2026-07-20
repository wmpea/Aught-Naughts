#!/usr/bin/env bash
# Auction management for AughtNaughts.
#
#   ./auction.sh start <tokenId> <reserveEth> <durationHours>   (owner)
#   ./auction.sh status <tokenId>
#   ./auction.sh bid <tokenId> <amountEth>                      (anyone)
#   ./auction.sh settle <tokenId>                               (anyone, after end)
#   ./auction.sh cancel <tokenId>                               (owner, no bids only)
#
# Env (or .env): NFT, RPC_URL, ACCOUNT

set -euo pipefail
PRESET_ACCOUNT="${ACCOUNT:-}"
[ -f .env ] && source .env
[ -n "$PRESET_ACCOUNT" ] && ACCOUNT="$PRESET_ACCOUNT"

: "${NFT:?set NFT}"
: "${RPC_URL:?set RPC_URL}"

CMD="${1:?usage: ./auction.sh start|status|bid|settle|cancel ...}"

case "$CMD" in
  start)
    : "${ACCOUNT:?set ACCOUNT}"
    TOKEN_ID="${2:?tokenId}"; RESERVE="${3:?reserve in ETH}"; HOURS="${4:?duration in hours}"
    cast send "$NFT" "startAuction(uint256,uint96,uint40)" \
      "$TOKEN_ID" "$(cast to-wei "$RESERVE" ether)" "$(( HOURS * 3600 ))" \
      --rpc-url "$RPC_URL" --account "$ACCOUNT"
    echo "Auction started for token $TOKEN_ID — reserve ${RESERVE} ETH, ${HOURS}h"
    ;;

  status)
    TOKEN_ID="${2:?tokenId}"
    RAW=$(cast call "$NFT" "auctions(uint256)(uint96,uint96,uint40,uint40,address,bool)" "$TOKEN_ID" --rpc-url "$RPC_URL")
    echo "auction($TOKEN_ID): [amount, reserve, startTime, endTime, bidder, settled]"
    echo "$RAW"
    NOW=$(date +%s)
    END=$(echo "$RAW" | sed -n '4p' | awk '{print $1}')
    if [ -n "$END" ] && [ "$END" -gt "$NOW" ] 2>/dev/null; then
      echo "time remaining: $(( (END - NOW) / 60 )) minutes"
    fi
    ;;

  bid)
    : "${ACCOUNT:?set ACCOUNT}"
    TOKEN_ID="${2:?tokenId}"; AMOUNT="${3:?amount in ETH}"
    cast send "$NFT" "createBid(uint256)" "$TOKEN_ID" \
      --value "$(cast to-wei "$AMOUNT" ether)" \
      --rpc-url "$RPC_URL" --account "$ACCOUNT"
    ;;

  settle)
    : "${ACCOUNT:?set ACCOUNT}"
    TOKEN_ID="${2:?tokenId}"
    cast send "$NFT" "settleAuction(uint256)" "$TOKEN_ID" \
      --rpc-url "$RPC_URL" --account "$ACCOUNT"
    echo "Settled token $TOKEN_ID"
    ;;

  cancel)
    : "${ACCOUNT:?set ACCOUNT}"
    TOKEN_ID="${2:?tokenId}"
    cast send "$NFT" "cancelAuction(uint256)" "$TOKEN_ID" \
      --rpc-url "$RPC_URL" --account "$ACCOUNT"
    echo "Canceled auction for token $TOKEN_ID"
    ;;

  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
