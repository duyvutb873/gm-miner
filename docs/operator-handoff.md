# Bàn giao vận hành miner (cho session Claude mới)

Tài liệu này là trạng thái và quy tắc làm việc của operator `duyvutb873`, để một
session mới tiếp tục ngay mà không phải hỏi lại. Cập nhật lần cuối: 2026-10-17 ~04:40Z.
Giao tiếp với user **bằng tiếng Việt**, ngắn gọn; báo cáo định kỳ 1–4 dòng.

## 1. Miner

| | |
|---|---|
| Network | mainnet, netuid 28 |
| Hotkey | `5Fsvv441XpSp8hQAKQxH5gKy1oucPjaLGfaaeSfADnGsi6uP`, UID 162 |
| Worker #1 | app-name `gm-mainnet-1`, worker `01M4WZ0VFVDPXMMM0ABXWBFZWJ`, CVM app `364943b25d6ea215b625a6ef7fda8c360f67bbee` (prod5) |
| Worker #2 | app-name `gm-mainnet-2`, worker `01M51WWJHKA38TTJ0K065HHWGN`, CVM app `b93cf08c7d4a6682d4f30c7010aba3ab1dadfa7e` (prod5) |
| Shell của user | **zsh** trên macOS (`read -p` của bash không chạy; dùng `read -rs "VAR?prompt: "`) |

Worker/CVM ID đổi sau mỗi lần redeploy — kiểm tra bằng `gmcli --network mainnet worker list`.

## 2. Offer hiện tại

| Lane | Upstream | Discount |
|---|---|---|
| `claude-opus-5-5` | anthropic (4 key slot) | **22.5%** |
| 10 lane Claude khác (fable-5, fable-5-1, haiku-4-5, haiku-5-5, opus-4-7, opus-4-8, opus-5, sonnet-4-6, sonnet-5, sonnet-5-5) | anthropic | **18%** |
| `kimi-k3` | engy | **20%** |

Đã rút: glm-5.3 (engy). Đang dự định: `deepinfra/zai-org/GLM-5.3-Flash` ở 10% (xem §5).

## 3. Kinh tế (để quyết giá)

- Thưởng ≈ **$0.97 alpha cho mỗi $1 phục vụ** (alpha ~ $9; hoà vốn khi alpha ~$9.3).
- Phục vụ $1 retail ở discount d → nhận 0.97×(1−d); lãi = 0.97×(1−d) − chi phí/retail.
- **Claude**: user mua credit 0.5 (key $200 giá $100). Lãi ≈ $0.30/$1 ở 18%, $0.25 ở 22.5%; hoà vốn ~48%.
  User xác nhận key **hợp pháp** (của bạn bè) — đừng nghi ngờ hay đề xuất giảm vì rủi ro key.
- **Engy kimi-k3**: $1.95/$9.75 vs retail $3/$15 → ~65% → lãi ~$0.13/$1 ở 20%.
- **Engy glm-5.3-flash**: 90% retail → không đáng. **Z.ai trực tiếp** = đúng giá retail → luôn lỗ.
- **DeepInfra** (khuyến mãi "limited-time", chưa có ngày kết thúc): GLM-5.3-Flash giảm 50% → chi phí 50% retail
  (lãi ~$0.37/$1 ở 10%); GLM-5.2 41%; GLM-5.3 49%; Kimi-K3 95% (giữ Engy).
- Không đua giá trên các lane Claude khác (bot ở 40–50% gần hoà vốn với giá vốn 0.5). Trên opus-5-5,
  miner chỉ 10% vẫn có $20–50/epoch → giá không phải yếu tố quyết định; **sticky session** mới là.

## 4. Bài học đã rút ra

- **Đừng rút offer / redeploy cả loạt.** Đổi key ở epoch 25747 bằng `undeclare-products --all` làm mất
  toàn bộ sticky session: opus-5-5 từ 131–375 req/epoch ($16–25) tụt còn 3–90 req ($0.4–9). Đối thủ
  `5Guq6eTE` hút luôn. Script đổi key giờ chạy **rolling** (giữ offer, thay từng worker).
- Lỗi lẻ tẻ trên 1 model thường là lỗi **toàn mạng** (fable-5-1, kimi-k3 epoch 25752–25755: 14–24 miner
  cùng lỗi). Luôn so lỗi của mình với toàn mạng (`epoch_history.py`) trước khi kết luận key hỏng.
  Lỗi tăng trên **nhiều model Claude cùng lúc** → nghi key cạn → bảo user chạy `gmcli --network mainnet worker list`
  (dòng `unverified key`).
- Gateway chọn slot key mỗi request (dùng song song, không lần lượt); miner không failover. Key nằm trong
  TEE từ lúc deploy → đổi key bắt buộc redeploy.
- Engy ổn định; chỉ nhắc nạp Engy khi kimi lỗi hàng loạt **riêng của user**.

## 5. Script

`scripts/rotate-claude-keys.sh` (bash 3.2-compatible; user giữ bản ở `~/rotate-claude-keys.sh` — nhắc họ
cập nhật từ repo, lỗi "không hiểu tuỳ chọn" nghĩa là bản cũ):

```
bash scripts/rotate-claude-keys.sh --dry-run            # xem kế hoạch
bash scripts/rotate-claude-keys.sh                      # đổi key Claude (nhập ẩn), rolling, giữ offer
bash scripts/rotate-claude-keys.sh --keep-keys          # chỉ redeploy rolling với key hiện có (sau set-api-keys --deepinfra …)
bash scripts/rotate-claude-keys.sh --withdraw           # cách cũ: rút offer, in lệnh khai báo lại
```
Rolling: worker phụ `worker remove` → `phala cvms delete` → `worker add`, chờ active + `GM_SETTLE_SECS` (600)
rồi dừng nếu có `unverified key`; chỉ sau đó mới xoá + `deploy` worker #1 (từ chối nếu registry không còn
liệt kê worker #1). Env: `GM_NETWORK`, `GM_PRIMARY_APP`, `GM_SECONDARY_APPS`, `GM_ACTIVE_TIMEOUT`, `GM_SETTLE_SECS`.

Kế hoạch DeepInfra user đang làm (bước kế tiếp):
1. Test key (zsh): `read -rs "DI?DeepInfra key: "; curl -sS https://api.deepinfra.com/v1/openai/chat/completions -H "Authorization: Bearer $DI" -H "Content-Type: application/json" -d '{"model":"zai-org/GLM-5.3-Flash","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' -w '\nHTTP %{http_code}\n'; unset DI` → cần HTTP 200.
2. `gmcli set-api-keys --deepinfra "<KEY>"`
3. `bash scripts/rotate-claude-keys.sh --keep-keys`
4. `gmcli --network mainnet declare-product --provider deepinfra --model zai-org/GLM-5.3-Flash --discount-pct 10`

## 6. Theo dõi (dữ liệu công khai, không cần credential)

`scripts/monitor/`:
- `gm_check.sh` — earnings 10 epoch + leaderboard epoch mới nhất theo từng product.
- `model_discounts.py <model>` — ai đang có traffic trên model đó, discount bao nhiêu.
- `epoch_history.py FROM TO [hotkey_prefix] [model]` — lịch sử theo epoch + lỗi của mình vs toàn mạng.
- `di_promo.sh` — giá DeepInfra thực trả (list × (1−discount)) cho GLM, tỷ lệ chi phí/retail, mức hoà vốn.

API: `https://registry.saygm.com/leaderboard[?epoch=N]`, `/miners/{hotkey}/earnings?limit=N` (gửi header
`User-Agent: curl/8`); `https://api.deepinfra.com/models/list` (trường `pricing.discount`, `discount_ends_at`;
`cents_per_*_token` là giá niêm yết, nhân 1e4 ra $/Mtok).

Kiểm tra định kỳ (user muốn tiếp tục tới 2026-10-24 hoặc khi họ bảo dừng; mỗi 120 phút, 240 nếu Claude đã rút):
1. `gm_check.sh`, `model_discounts.py claude-opus-5-5`, `di_promo.sh`.
2. Báo 1–4 dòng: thu nhập/hạng epoch mới, opus-5-5 traffic + discount đối thủ, lỗi (so toàn mạng), credit Claude.
3. **Khuyến mãi DeepInfra đổi** (discount giảm/hết hoặc có `ends_at`) → báo ngay dòng đầu; nếu user đang offer
   glm qua DeepInfra mà chi phí/retail > 0.97×(1−discount) → bảo rút:
   `gmcli --network mainnet undeclare-product --provider deepinfra --model zai-org/GLM-5.3-Flash`.
4. Credit Claude: ước tính ~$600 lúc epoch 25762 (trừ dần Σ Claude served ÷ (1−discount)); nhắc khi ≤ $80.
   Ước tính này từng sai vì có nhiều key/tài khoản — chỉ coi là gần đúng.

Số liệu gần nhất: epoch 25762 $8.64, 0 lỗi; lifetime $721.5. Tổng mạng ~$950–1050/epoch.

## 7. Quy tắc an toàn (bắt buộc)

- Không bao giờ hỏi, nhận hay xử lý API key, seed phrase hay nội dung `.env` của user; user tự chạy lệnh
  có key trên máy mình và không dán key vào chat.
- Không ký extrinsic ví; không giúp lách attestation/kiểm tra của registry.
- Khuyên không vi phạm ToS (ví dụ: không bán lại GLM Coding Plan của Z.ai qua API).
- `gmcli` không xoá CVM; xoá CVM là hành động của operator (script làm khi user chạy).
