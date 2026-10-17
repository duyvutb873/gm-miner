# Who serves a model in the latest epoch, at what discount: python3 model_discounts.py claude-opus-5-5
import sys, json, urllib.request
model = sys.argv[1]                      # e.g. kimi-k3, glm-5.3, claude-sonnet-5-5
req = urllib.request.Request("https://registry.saygm.com/leaderboard", headers={"User-Agent": "curl/8"})
d = json.load(urllib.request.urlopen(req, timeout=30))
rows = []
for e in d["entries"]:
    for p in e["products"]:
        if p["model"] == model:
            rows.append((p["miner_discount_bp"] / 100, e["miner_hotkey"][:8], p["provider"], p["successful_requests"], int(p["earnings_ndollars"]) / 1e9))
print("epoch", d["epoch_id"], d["finalized_at"], "-", model, "-", len(rows), "miners co traffic")
print("%8s  %-9s %-10s %6s %10s" % ("DISCOUNT", "HOTKEY", "PROVIDER", "REQ", "SERVED$"))
for r in sorted(rows, key=lambda r: -r[3]):
    print("%7.2f%%  %-9s %-10s %6d %10.2f" % r)
