#!/usr/bin/env bash
# Make a fresh key without printing it: the private key goes only into the file (mode 600).
#   script/new_key.sh [path]   (default ~/.hyperevm-amm-testnet.key)
set -euo pipefail
out=${1:-$HOME/.hyperevm-amm-testnet.key}
[ -e "$out" ] && { echo "$out already exists; not overwriting" >&2; exit 1; }
umask 077
cast wallet new --json | python3 -c '
import json, sys
w = json.load(sys.stdin)[0]
open(sys.argv[1], "w").write(w["private_key"])
print("address", w["address"])
' "$out"
ls -l "$out"
