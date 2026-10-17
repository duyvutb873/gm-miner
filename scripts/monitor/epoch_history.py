# Per-epoch history from the public leaderboard (cached under ./.lbcache).
#   python3 epoch_history.py FROM_EPOCH TO_EPOCH [HOTKEY_PREFIX] [MODEL]
# Prints the miner's total and MODEL earnings per epoch, network total, and
# per-model failures (yours vs whole network) — use it to tell "my key/upstream
# is broken" (only you fail) from "the model is down" (many miners fail).
import json, os, sys, urllib.request, collections
a, b = int(sys.argv[1]), int(sys.argv[2])
hk = sys.argv[3] if len(sys.argv) > 3 else "5Fsvv441"
model = sys.argv[4] if len(sys.argv) > 4 else "claude-opus-5-5"
cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".lbcache"); os.makedirs(cache, exist_ok=True)
def lb(e):
    f = os.path.join(cache, f"{e}.json")
    if not os.path.exists(f):
        r = urllib.request.Request(f"https://registry.saygm.com/leaderboard?epoch={e}", headers={"User-Agent": "curl/8"})
        open(f, "wb").write(urllib.request.urlopen(r, timeout=30).read())
    return json.load(open(f))
mine_f, net_f = collections.Counter(), collections.Counter()
print("epoch   net$   mine$  %s$ (req,disc)" % model)
for e in range(a, b + 1):
    d = lb(e)
    for x in d["entries"]:
        for p in x["products"]:
            if p["failed_requests"]: net_f[p["model"]] += p["failed_requests"]
    m = [x for x in d["entries"] if x["miner_hotkey"].startswith(hk)]
    if not m: print(e, "not listed"); continue
    m = m[0]; o = [p for p in m["products"] if p["model"] == model]
    for p in m["products"]: mine_f[p["model"]] += p["failed_requests"]
    os_ = f"{int(o[0]['earnings_ndollars'])/1e9:6.2f} ({o[0]['total_requests']},{o[0]['miner_discount_bp']/100:.1f}%)" if o else "-"
    print(e, f"{int(d['total_earnings_ndollars'])/1e9:6.0f} {int(m['earnings_ndollars'])/1e9:7.2f}  {os_}")
print("failures mine / network:", [(k, mine_f[k], net_f[k]) for k in sorted(mine_f, key=lambda k: -mine_f[k]) if mine_f[k]])
