#!/usr/bin/env bash
# Swap the Anthropic (Claude) keys on every worker and redeploy them.
#
# Keys live inside the TEE from deploy time, so `gmcli set-api-keys` alone
# changes nothing on a running worker: each CVM has to be torn down and
# redeployed.
#
# Default (rolling): offers stay up and the workers are replaced one at a
# time, so at least one worker keeps serving — and keeps its sticky sessions —
# the whole way through. Withdrawing every offer drops every session to other
# miners, and winning them back takes many epochs.
#
#   1. check every new key against Anthropic (HTTP 200 + a 1-token request)
#   2. `set-api-keys --anthropic "k1;k2;..."`
#   3. for each secondary worker: `worker remove` FIRST (the gateway stops
#      routing to it), then `phala cvms delete`, then `worker add`; wait for
#      `active`, give the registry GM_SETTLE_SECS to probe the new keys, and
#      stop if any of its slots reads `unverified key` — worker #1 is still
#      serving on the old keys at that point, so nothing is lost
#   4. redeploy worker #1 (phala delete -> deploy), refusing to deploy if the
#      registry no longer lists it: `deploy` refreshes the oldest live worker,
#      so it would overwrite a secondary instead. Worker #1 cannot be
#      deregistered first, so a request or two may fail while it restarts
#   5. flag any `unverified key` slot
#
# --keep-keys skips steps 1-2: no Claude keys are asked for or changed, the
# workers are just redeployed (rolling) with whatever `~/.gmcli/config.json`
# holds now. Use it after `gmcli set-api-keys --deepinfra ...` (or any other
# provider) so the new key reaches the TEE without touching the Claude slots.
#
# --withdraw restores the old behaviour: snapshot the offers, withdraw them all
# before redeploying, and print the re-declare commands at the end (offers are
# NOT re-declared automatically).
#
#   scripts/rotate-claude-keys.sh                 # prompts for keys (hidden)
#   scripts/rotate-claude-keys.sh KEY1 KEY2       # keys as args (lands in shell history)
#   scripts/rotate-claude-keys.sh --dry-run       # print the plan, change nothing
#   scripts/rotate-claude-keys.sh --withdraw      # withdraw offers during the redeploy
#   scripts/rotate-claude-keys.sh --keep-keys     # redeploy only, keep current keys
#
# Environment overrides:
#   GM_NETWORK          (default mainnet)
#   GM_PRIMARY_APP      (default gm-mainnet-1)  app-name of worker #1
#   GM_SECONDARY_APPS   (default gm-mainnet-2)  space-separated app-names
#   GM_ACTIVE_TIMEOUT   (default 900)           seconds to wait for `active`
#   GM_SETTLE_SECS      (default 600)           rolling: wait after a secondary is
#                                               active before checking its key slots
#
# Written for bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.
set -euo pipefail

NETWORK="${GM_NETWORK:-mainnet}"
PRIMARY_APP="${GM_PRIMARY_APP:-gm-mainnet-1}"
SECONDARY_APPS="${GM_SECONDARY_APPS:-gm-mainnet-2}"
ACTIVE_TIMEOUT="${GM_ACTIVE_TIMEOUT:-900}"
SETTLE_SECS="${GM_SETTLE_SECS:-600}"
POLL_SECS=20
PROBE_MODEL="claude-haiku-5-5"

DRY_RUN=0
ASSUME_YES=0
WITHDRAW=0
KEEP_KEYS=0
KEYS=()

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  echo "✗ $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    --withdraw) WITHDRAW=1 ;;
    --keep-keys) KEEP_KEYS=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        KEYS+=("$1")
        shift
      done
      break
      ;;
    -*) die "không hiểu tuỳ chọn: $1 (xem --help)" ;;
    *) KEYS+=("$1") ;;
  esac
  shift
done

for cmd in gmcli phala curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "thiếu lệnh '$cmd' trong PATH"
done

STEP="khởi động"
UNDECLARED=0
REDECLARE_FILE=""

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo >&2
    echo "✗ Script dừng ở bước: $STEP (mã $rc)" >&2
    if [ "$UNDECLARED" -eq 1 ] && [ -n "$REDECLARE_FILE" ]; then
      echo "  Các offer ĐÃ BỊ RÚT. Khi worker active lại, khai báo lại bằng:" >&2
      echo "    bash $REDECLARE_FILE" >&2
    fi
  fi
}
trap on_exit EXIT

gm() { gmcli --network "$NETWORK" "$@"; }

# Destructive or state-changing commands go through run so --dry-run can show them.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

mask() {
  local k="$1"
  if [ "${#k}" -gt 8 ]; then echo "…${k: -4}"; else echo "…"; fi
}

# --- 1. keys --------------------------------------------------------------

if [ "$KEEP_KEYS" -eq 1 ] && [ "${#KEYS[@]}" -gt 0 ]; then
  die "--keep-keys không nhận key (bỏ key đi, hoặc bỏ --keep-keys để đổi key)"
fi

if [ "$KEEP_KEYS" -eq 0 ]; then
STEP="nhập key"
if [ "${#KEYS[@]}" -eq 0 ]; then
  echo "Nhập từng key Claude (không hiện trên màn hình). Enter trống để kết thúc."
  while :; do
    k=""
    IFS= read -rs -p "  key #$((${#KEYS[@]} + 1)): " k || true
    echo
    [ -z "$k" ] && break
    KEYS+=("$k")
  done
fi
[ "${#KEYS[@]}" -ge 1 ] || die "cần ít nhất 1 key"
[ "${#KEYS[@]}" -le 8 ] || die "tối đa 8 key (gm giới hạn 8 slot mỗi provider)"
for k in "${KEYS[@]}"; do
  case "$k" in
    *";"* | *" "* | *$'\t'*) die "key $(mask "$k") chứa ';' hoặc khoảng trắng" ;;
  esac
done

# Headers go through curl's config on stdin so the key never shows up in `ps`.
anthropic_curl() {
  local key="$1"
  shift
  printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n' "$key" |
    curl -sS -K - "$@"
}

STEP="kiểm tra key"
echo "== 1. Kiểm tra ${#KEYS[@]} key với Anthropic"
for k in "${KEYS[@]}"; do
  code="$(anthropic_curl "$k" -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models || echo 000)"
  [ "$code" = "200" ] || die "key $(mask "$k"): /v1/models trả HTTP $code (key sai hoặc đã bị thu hồi)"
  resp="$(anthropic_curl "$k" -w $'\n%{http_code}' https://api.anthropic.com/v1/messages \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$PROBE_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" || echo $'\n000')"
  code="${resp##*$'\n'}"
  if [ "$code" != "200" ]; then
    reason="$(printf '%s' "${resp%$'\n'*}" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["error"]["message"][:120])
except Exception: print("")' 2>/dev/null || true)"
    die "key $(mask "$k"): request thử trả HTTP $code ${reason:+— $reason}"
  fi
  echo "  ✓ key $(mask "$k") OK"
done
else
  echo "== 1. --keep-keys: giữ nguyên key trong config, chỉ redeploy"
fi

# --- 2. snapshot offers -----------------------------------------------------

offers=""
if [ "$WITHDRAW" -eq 1 ]; then
STEP="đọc offer hiện tại"
echo "== Lưu danh sách offer đang mở (--withdraw)"
status_out="$(gm status)"
offers="$(printf '%s\n' "$status_out" | awk '
  /^PROVIDER[ ]+MODEL/ { inside = 1; next }
  inside && /^-+$/     { next }
  inside && NF == 0    { inside = 0 }
  inside && NF >= 5 && $(NF-1) == "yes" { d = $3; sub(/%$/, "", d); print $1, $2, d }
')"
[ -n "$offers" ] || echo "  (không có offer nào đang mở — sẽ không cần khai báo lại)"

mkdir -p "$HOME/.gmcli"
REDECLARE_FILE="$HOME/.gmcli/redeclare-$(date -u +%Y%m%dT%H%M%SZ).sh"
{
  echo "#!/usr/bin/env bash"
  echo "# Khai báo lại các offer đã rút bởi rotate-claude-keys.sh"
  printf '%s\n' "$offers" | while read -r p m d; do
    [ -n "${p:-}" ] || continue
    echo "gmcli --network $NETWORK declare-product --provider $p --model $m --discount-pct $d --yes"
  done
} >"$REDECLARE_FILE"
printf '%s\n' "$offers" | sed '/^$/d; s/^/  /'
echo "  → lệnh khai báo lại: $REDECLARE_FILE"
fi

# --- helpers: phala + worker list ------------------------------------------

cvm_app_id() {
  phala cvms list --json 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
try:
    rows = json.load(sys.stdin).get("items") or []
except Exception:
    rows = []
for r in rows:
    n = r.get("name") or r.get("cvm") or r.get("cvmName")
    a = r.get("app_id") or r.get("appId")
    if n == name and a:
        print(a)
        break
' "$1" || true
}

worker_list() { gm worker list 2>/dev/null || true; }

# First table row whose endpoint contains the app_id; "" when absent.
worker_field_for_app() {
  [ -n "$1" ] || return 0
  worker_list | grep -F "$1" | grep -E '^[0-9A-Z]{26}[[:space:]]' | head -1 | awk -v f="$2" '{print $f}'
}

# True when `worker list` prints an `unverified key` line under this worker's
# health block ("<worker_id> (<status>)" ... up to the next blank line).
worker_has_unverified() {
  [ -n "$1" ] || return 1
  worker_list | awk -v w="$1" '
    index($0, w " (") == 1 { inside = 1; next }
    inside && NF == 0      { inside = 0 }
    inside && /unverified key/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

# Rolling mode: before the next worker goes down, make sure this one actually
# serves Claude on the new keys.
settle_and_check_keys() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$WITHDRAW" -eq 1 ] && return 0
  local app_id="$1" wid
  wid="$(worker_field_for_app "$app_id" 1)"
  echo "  … chờ ${SETTLE_SECS}s để registry kiểm tra key trên worker mới ($wid)"
  sleep "$SETTLE_SECS"
  if worker_has_unverified "$wid"; then
    worker_list
    die "worker mới $wid có slot 'unverified key' — DỪNG trước khi đụng worker #1 (worker #1 vẫn chạy key cũ, offer vẫn mở). Kiểm tra key rồi chạy lại script."
  fi
  echo "  ✓ không có slot 'unverified key'"
}

DELETE_FLAG=""
phala_help="$(phala cvms delete --help 2>&1 || true)"
case "$phala_help" in
  *--force*) DELETE_FLAG="--force" ;;
  *--yes*) DELETE_FLAG="--yes" ;;
esac

delete_cvm() {
  # Without a known non-interactive flag phala asks for confirmation itself.
  if [ -n "$DELETE_FLAG" ]; then
    run phala cvms delete "$1" "$DELETE_FLAG"
  else
    run phala cvms delete "$1"
  fi
}

wait_cvm_gone() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  local waited=0
  while [ -n "$(cvm_app_id "$1")" ]; do
    [ "$waited" -lt 300 ] || die "CVM '$1' vẫn còn sau 300s"
    sleep 10
    waited=$((waited + 10))
  done
}

wait_active() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  local app_id="$1" waited=0 st
  while :; do
    st="$(worker_field_for_app "$app_id" 2)"
    if [ "$st" = "active" ]; then
      echo "  ✓ active"
      return 0
    fi
    [ "$waited" -lt "$ACTIVE_TIMEOUT" ] || die "worker ($app_id) chưa active sau ${ACTIVE_TIMEOUT}s (trạng thái: ${st:-chưa thấy})"
    echo "  … ${st:-chưa thấy trong registry} (${waited}s)"
    sleep "$POLL_SECS"
    waited=$((waited + POLL_SECS))
  done
}

# --- plan + confirm ---------------------------------------------------------

STEP="kiểm tra worker"
primary_old="$(cvm_app_id "$PRIMARY_APP")"
primary_wid="$(worker_field_for_app "$primary_old" 1)"
[ -n "$primary_old" ] || die "không thấy CVM '$PRIMARY_APP' trên Phala (đặt GM_PRIMARY_APP nếu tên khác)"
[ -n "$primary_wid" ] || die "registry không liệt kê worker của '$PRIMARY_APP' — dừng để tránh deploy ghi đè worker phụ"

echo
echo "Kế hoạch (network $NETWORK):"
if [ "$KEEP_KEYS" -eq 1 ]; then
  key_plan="giữ nguyên key hiện có trong config"
else
  key_plan="đặt ${#KEYS[@]} key Claude mới"
fi
if [ "$WITHDRAW" -eq 1 ]; then
  echo "  - rút toàn bộ offer, $key_plan"
else
  echo "  - GIỮ offer, $key_plan, thay lần lượt từng worker"
fi
for app in $SECONDARY_APPS; do
  echo "  - redeploy worker phụ '$app' (CVM $(cvm_app_id "$app"))"
done
echo "  - redeploy worker #1 '$PRIMARY_APP' (CVM $primary_old, worker $primary_wid)"
if [ "$WITHDRAW" -eq 1 ]; then
  echo "  Mỗi worker mất khoảng 5–10 phút; trong lúc đó không có offer nào mở."
else
  echo "  Mỗi worker mất khoảng 5–10 phút (+${SETTLE_SECS}s chờ kiểm tra key); worker còn lại vẫn phục vụ."
  [ -n "$SECONDARY_APPS" ] || echo "  ! Không có worker phụ: trong lúc redeploy worker #1 sẽ không worker nào phục vụ."
fi
if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  read -r -p "Tiếp tục? [y/N] " ans
  case "$ans" in y | Y | yes) ;; *) die "đã huỷ, chưa thay đổi gì" ;; esac
fi

# --- 3. withdraw ------------------------------------------------------------

STEP="rút offer"
if [ "$WITHDRAW" -eq 1 ] && [ -n "$offers" ]; then
  echo "== Rút toàn bộ offer"
  run gmcli --network "$NETWORK" undeclare-products --all
  UNDECLARED=1
fi

# --- 4. keys ----------------------------------------------------------------

STEP="lưu key"
echo "== 2. Lưu key mới vào config"
if [ "$KEEP_KEYS" -eq 1 ]; then
  echo "  (bỏ qua — --keep-keys)"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "  [dry-run] gmcli set-api-keys --anthropic \"<${#KEYS[@]} key>\""
else
  # Inside the branch: "${KEYS[*]}" on an empty array trips `set -u` in bash 3.2.
  joined="$(
    IFS=";"
    echo "${KEYS[*]}"
  )"
  gmcli set-api-keys --anthropic "$joined" >/dev/null
  echo "  ✓ đã lưu ${#KEYS[@]} key"
fi

# --- 5. secondaries ---------------------------------------------------------

for app in $SECONDARY_APPS; do
  STEP="redeploy $app"
  echo "== 3. Redeploy worker phụ '$app'"
  old="$(cvm_app_id "$app")"
  wid="$(worker_field_for_app "$old" 1)"
  # Deregister before teardown so the gateway stops routing to a dying CVM.
  if [ -n "$wid" ]; then run gmcli --network "$NETWORK" worker remove "$wid"; else echo "  (registry không có worker của '$app')"; fi
  if [ -n "$old" ]; then delete_cvm "$old"; else echo "  (không có CVM '$app' — bỏ qua bước xoá)"; fi
  wait_cvm_gone "$app"
  run gmcli --network "$NETWORK" worker add --app-name "$app" --yes
  new_app="$(cvm_app_id "$app")"
  wait_active "$new_app"
  settle_and_check_keys "$new_app"
done

# --- 6. worker #1 -----------------------------------------------------------

STEP="redeploy $PRIMARY_APP"
echo "== 4. Redeploy worker #1 '$PRIMARY_APP'"
delete_cvm "$primary_old"
wait_cvm_gone "$PRIMARY_APP"
if [ "$DRY_RUN" -eq 0 ]; then
  worker_list | grep -qF "$primary_wid" ||
    die "registry đã gỡ worker #1 ($primary_wid) — KHÔNG chạy deploy (sẽ ghi đè worker phụ). Dùng: gmcli --network $NETWORK worker remove $primary_wid; gmcli --network $NETWORK worker add --app-name $PRIMARY_APP"
fi
run gmcli --network "$NETWORK" deploy --app-name "$PRIMARY_APP" --yes
new_primary="$(cvm_app_id "$PRIMARY_APP")"
wait_active "$new_primary"
if [ "$DRY_RUN" -eq 0 ]; then
  got="$(worker_field_for_app "$new_primary" 1)"
  [ "$got" = "$primary_wid" ] || echo "  ! worker #1 có ID $got, khác ID cũ $primary_wid — kiểm tra lại worker list"
fi

# --- 7. verify + hand back --------------------------------------------------

STEP="kiểm tra cuối"
echo "== 5. Kiểm tra"
if [ "$DRY_RUN" -eq 0 ]; then
  wl="$(worker_list)"
  printf '%s\n' "$wl"
  if printf '%s\n' "$wl" | grep -qi "unverified key"; then
    echo
    echo "  ! Có slot key không xác minh được (xem dòng 'unverified key' ở trên)."
    echo "    Kiểm tra key đó rồi chạy lại script với danh sách key đúng."
  fi
fi

trap - EXIT
echo
if [ "$UNDECLARED" -eq 1 ]; then
  echo "✓ Xong. Khai báo lại offer (chạy cả file hoặc từng dòng):"
  echo "    bash $REDECLARE_FILE"
  sed '1,2d; s/^/    /' "$REDECLARE_FILE"
  echo "  Các làn Claude sẽ eligible sau khoảng 10–15 phút, khi registry kiểm tra lại key."
else
  echo "✓ Xong. Offer vẫn mở suốt quá trình, không cần khai báo lại."
  echo "  Kiểm tra: gmcli --network $NETWORK status"
fi
