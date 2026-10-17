#!/usr/bin/env bash
# Public-data health check for a gm mainnet miner (no credentials needed).
#   scripts/monitor/gm_check.sh [HOTKEY]
H="${1:-${GM_HOTKEY:-5Fsvv441XpSp8hQAKQxH5gKy1oucPjaLGfaaeSfADnGsi6uP}}"
UA='User-Agent: curl/8'
echo "=== $(date -u +%FT%TZ)"
echo "--- registry earnings (last 10 finalized epochs)"
curl -sS --max-time 30 -H "$UA" "https://registry.saygm.com/miners/$H/earnings?limit=10" | python3 -c '
import sys,json; d=json.load(sys.stdin)
print("lifetime $%.4f" % (int(d["total_earnings_ndollars"])/1e9))
for e in d.get("epochs",[]): print("  epoch %s  $%.2f  ok %s fail %s  %s" % (e["epoch_id"], int(e["earnings_ndollars"])/1e9, e["successful_requests"], e["failed_requests"], e["finalized_at"]))'
echo "--- leaderboard (latest epoch)"
curl -sS --max-time 30 -H "$UA" https://registry.saygm.com/leaderboard | python3 -c '
import sys,json; d=json.load(sys.stdin); H=sys.argv[1]
m=[x for x in d["entries"] if x["miner_hotkey"]==H]
print("epoch",d["epoch_id"],d["finalized_at"],"miners",len(d["entries"]),"total $%.2f"%(int(d["total_earnings_ndollars"])/1e9))
if m:
  x=m[0]; print("rank",x["rank"],"share %.2f%%"%(x["share_bp"]/100),"$%.4f"%(int(x["earnings_ndollars"])/1e9),"req ok/fail",x["successful_requests"],x["failed_requests"],"reliability_bp",x["reliability_bp"],"workers",x.get("worker_count"))
  for p in sorted(x["products"],key=lambda p:-int(p["earnings_ndollars"])): print("  ",p["provider"],p["model"],"$%.4f"%(int(p["earnings_ndollars"])/1e9),"req",p["total_requests"],"fail",p["failed_requests"],"disc %.2f%%"%(p["miner_discount_bp"]/100))
else: print("not on leaderboard")' "$H"
