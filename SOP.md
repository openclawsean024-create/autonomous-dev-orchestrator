# Autonomous Dev Orchestrator — SOP

日期：2026-09-27

## 執行順序

1. Patrol controller 讀 canonical Notion Project DB。
2. 驗證 SPEC URL、GitHub URL、本地 repo、clean worktree、risk tier。
3. 計算 requirement fingerprint，取得 lease；已有 active lease 則跳過。
4. 建立 bounded `GOAL.md`，包含 FR、AC、non-goals、stop conditions。
5. Planner 只讀分析；MiniMax CLI 執行 Developer。
6. 跑目標 repo 的 deterministic quality gate。
7. Codex QA 在 isolated read-only copy 驗收。
8. QA 失敗時由 MiniMax Integrator 修復，算同一個 implementation cycle；修復後重新跑 gate 與 QA。
9. 連續 3 個完整 MiniMax cycle 仍失敗，才把 evidence bundle 交給 ChatGPT Developer。
10. ChatGPT 接手後再次跑 deterministic gate、獨立 QA、Final Review。
11. 通過後自動 commit / push / PR / merge；merge 前仍檢查 required checks、branch protection、risk gate。
12. 自動 production deploy，60 秒內做 HTTP smoke test；非 200 時 rollback、通知 Sean、Notion 標記阻塞。
13. 只有 GitHub、local、Vercel、Notion SHA 完成驗證後，才標記 `已上線`。

## MiniMax quota policy

- 使用 pinned `mcode` CLI 與同一 session workspace。
- quota / 429 / rate-limit：等待 2 小時，以 `mcode exec --continue` resume，最多 5 次 wakeup。
- wakeup 不增加三次 implementation cycle。
- authentication、permission、harness、程式錯誤不走 quota recovery，直接停下並保留證據。

## Retry / stop policy

- 相同 blocker 未有新 evidence 或 plan revision，不得盲目重試。
- 規格矛盾、缺少資訊、需要 Sean 決策時，轉 `blocked`。
- 安全敏感變更轉 `需人審`；不得透過 ChatGPT fallback 自動放行。
- 每個 requirement 最多 3 次 MiniMax cycle + 1 次 ChatGPT takeover；仍失敗則 `blocked`。

## Release gate

自動化允許 push、開 PR、merge 與 production deploy，但必須同時滿足：

- all FR / AC 通過
- deterministic checks PASS
- independent QA PASS
- final review PASS
- GitHub required checks PASS
- 無未處理高風險變更
- Notion sync 可完成
- deploy smoke test HTTP 200

## Notion failure handling

Notion read 失敗：不派新任務。Notion write 失敗：保留 release evidence，將 run 標記 `notion_sync_failed`，不得宣告完成。恢復後由 idempotent sync job 補寫，不得建立第二筆 Project row。
