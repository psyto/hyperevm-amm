"""Send USDC on HyperCore from the key holder to an address (e.g. a contract's Core account).

    uv run --with hyperliquid-python-sdk python -I script/core_send.py <to> <usd> [--mainnet]
    uv run --with hyperliquid-python-sdk python -I script/core_send.py --state <addr> [--mainnet]

Reads the private key from KEY_FILE (default ~/.hyperevm-amm-testnet.key). Sending to an address
with no HyperCore account creates one.
"""
import json, os, sys
from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.info import Info
from hyperliquid.utils import constants

url = constants.MAINNET_API_URL if "--mainnet" in sys.argv else constants.TESTNET_API_URL
args = [a for a in sys.argv[1:] if a != "--mainnet"]
# empty metadata: these calls need none, and the SDK fails to parse testnet's spot list
# USDC as spotSend names it ("name:tokenId"), from spotMeta
USDC = {constants.TESTNET_API_URL: "USDC:0xeb62eee3685fc4c43992febcd9e75443",
        constants.MAINNET_API_URL: "USDC:0x6d1e7cde53ba9467b783cb7c530ce054"}
empty = dict(meta={"universe": []}, spot_meta={"universe": [], "tokens": []}, perp_dexs=[""])

if args[0] == "--state":
    info = Info(url, skip_ws=True, **empty)
    user = args[1]
    for q in ({"type": "userAbstraction"}, {"type": "spotClearinghouseState"}, {"type": "clearinghouseState"},
              {"type": "openOrders"}, {"type": "userFills"}):
        print(q["type"], json.dumps(info.post("/info", {**q, "user": user}))[:800])
    sys.exit()

key = open(os.path.expanduser(os.environ.get("KEY_FILE", "~/.hyperevm-amm-testnet.key"))).read().strip()
wallet = Account.from_key(key)
ex = Exchange(wallet, url, **empty)
print("from", wallet.address, "api", url)
# usdSend and spotSend are both disabled while the sender has a unified account; sendAsset
# (spot -> spot) works. The recipient gets it in its spot balance.
print(ex.send_asset(args[0], "spot", "spot", os.environ.get("TOKEN", USDC[url]), float(args[1])))
