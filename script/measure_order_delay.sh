#!/usr/bin/env bash
# Measure how long a CoreWriter IOC takes to run: EVM block time of the tx -> Core fill time.
#   PROBE=0x... ROUNDS=5 script/measure_order_delay.sh
# The probe needs USDC on its Core account (script/core_send.py). Each round buys ~12 USDC of
# HYPE on the spot market and sells it back, so each costs about the bid/ask spread.
set -euo pipefail
cd "$(dirname "$0")/.."
source script/lib.sh
P=${PROBE:?probe address}
ROUNDS=${ROUNDS:-5}
COIN=${COIN:-@1035}
ASSET=${ASSET:-11035}
SZ=${SZ:-30000000} # 0.3 HYPE, 1e8 units

book() { api "{\"type\":\"l2Book\",\"coin\":\"$COIN\"}"; }
# limit = best ask × 1.03 (buy) or best bid × 0.97 (sell), 5 significant figures, 1e8 units
limit() {
  book | python3 -c "
import json,sys,math
b=json.load(sys.stdin)['levels']; side='$1'
px=float(b[1][0]['px'])*1.03 if side=='buy' else float(b[0][0]['px'])*0.97
d=5-int(math.floor(math.log10(px)))-1
px=(math.ceil if side=='buy' else math.floor)(px*10**d)/10**d
print(int(round(px*1e8)))"
}
fills_after() { api "{\"type\":\"userFillsByTime\",\"user\":\"$P\",\"startTime\":$1}"; }

for i in $(seq 1 "$ROUNDS"); do
  for side in ${SIDES:-buy sell}; do
    px=$(limit $side); isBuy=$([ $side = buy ] && echo true || echo false)
    t0ms=$(( $(date +%s) * 1000 - 5000 ))
    out=$(cast send --legacy --async "$P" "order(uint32,bool,uint64,uint64,bool,uint8,uint128)" \
      "$ASSET" "$isBuy" "$px" "$SZ" false 3 0 --rpc-url "$R" --private-key "$K" 2>&1) || true
    hash=$(echo "$out" | grep -oE '0x[0-9a-f]{64}' | head -1)
    [ -n "$hash" ] || { echo "send failed: $out" >&2; exit 1; }
    blk=""
    for _ in $(seq 1 30); do blk=$(rd receipt "$hash" blockNumber 2>/dev/null) && [ -n "$blk" ] && break; sleep 2; done
    bts=$(rd block "$blk" --field timestamp)
    fill=""
    for _ in $(seq 1 30); do
      fill=$(fills_after "$t0ms" | python3 -c "
import json,sys
f=[x for x in json.load(sys.stdin) if x['side']==('B' if '$side'=='buy' else 'A')]
print(min(x['time'] for x in f) if f else '')")
      [ -n "$fill" ] && break; sleep 2
    done
    if [ -z "$fill" ]; then echo "round $i $side: no fill (block $blk)"; continue; fi
    echo "round $i $side: block $blk ts $bts  fill $fill  delay $(( fill - bts * 1000 )) ms"
    sleep 3
  done
done
