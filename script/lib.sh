# Helpers for driving testnet by hand. `source script/lib.sh`.
# The public testnet RPC rate-limits hard (-32005). A rate-limited `cast send` may still have
# been broadcast, so `tx` never resends: it checks the nonce first and only reports.
R=${RPC_URL:-https://rpc.hyperliquid-testnet.xyz/evm}
K=$(cat "${KEY_FILE:-$HOME/.hyperevm-amm-testnet.key}")
ME=$(cast wallet address --private-key "$K")

# Read with retries.
rd() {
  local out i
  for i in 1 2 3 4 5 6 7 8; do
    if out=$(cast "$@" --rpc-url "$R" 2>&1); then echo "$out"; return 0; fi
    case "$out" in *rate*) sleep $((i * 2));; *) echo "$out" >&2; return 1;; esac
  done
  echo "$out" >&2; return 1
}

# Send once. Waits for the nonce to move rather than resending.
tx() {
  local n0 out i
  n0=$(rd nonce "$ME") || return 1
  out=$(cast send --legacy --async "$@" --rpc-url "$R" --private-key "$K" 2>&1)
  echo "sent: $out"
  for i in $(seq 1 30); do
    sleep 2
    [ "$(rd nonce "$ME")" -gt "$n0" ] && { echo "mined (nonce $n0)"; return 0; }
  done
  echo "nonce did not move: check $out" >&2; return 1
}

# Core-side state from the info API (no RPC limit).
api() { curl -s https://api.hyperliquid-testnet.xyz/info -H 'content-type: application/json' -d "$1"; }
