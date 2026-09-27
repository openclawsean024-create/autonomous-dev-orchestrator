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

## MiniMax Agent Team execution

MiniMax Developer cycle 採 team-based 執行，但保留三輪 cycle + ChatGPT takeover、獨立 QA 與 Final Review 的整體政策不變。

1. **Roster（由 `config/orchestrator.json` 的 `developerTeam` 定義）**
   - implementation owner：唯一 writer，僅寫入自身 owned paths。
   - edge-case / test-coverage inspector：read-only，產出 findings、edge-case 列表與建議測試；不可修改程式碼。
   - integration coordinator（可選，預設 `coordinatorDefaultEnabled: false`）：在 `config/orchestrator.json` 內以 `enabled` 旗標表示啟用；跨多模組整合時顯式設為 `true`，其餘情況保留 `false` 或自 roster 移除。略過或 disabled 時，`team-exec.sh` 必須留下 `skipped` 證據。

2. **Execution mode（由 dispatcher capability probe 決定）**
   - `preferredMode`: `concurrent` — 當 pinned `mcode` 支援 Agent Team / subagent concurrency 時啟用。
   - `fallbackMode`: `sequential-focused-subagents` — 不支援 concurrency 時，依序執行 owner → inspector → coordinator，並於 evidence 內填寫 `fallbackReason` 與 capability probe 結果。
   - dispatcher 不得自行發明未經 capability probe 確認的 CLI 旗標。

3. **Ownership 與 single-writer barrier**
   - owner / inspector / coordinator 各自的 owned paths 必須 disjoint。
   - coordinator 必須等待 owner 與 inspector 完成標記，才可寫入整合檔。
   - inspector 與 QA / Final Reviewer 永遠 read-only。

4. **Developer handoff evidence（由 `scripts/manifest.sh` 落盤）**
   - team roster 與 file ownership
   - `executionMode` 與 `fallbackReason`（若為 fallback）
   - changed files（含 tracked、staged、untracked 三類）
   - 每個 deterministic check 的 exact command、numeric exit code、output reference
   - owner / inspector / coordinator 的 findings 與 unresolved risks
   - 每個 implementation cycle 寫入不可變的 `handoff-cycle-N.json`；`handoff.json` 為當下 cycle 的鏡像，前一輪不得覆寫。

5. **QA 與 Final Reviewer 仍為獨立 read-only**
   - QA / Final Reviewer 不在 team roster 內，不接受 team 的直接寫入。
   - ChatGPT takeover 後同樣由獨立 QA / Final Reviewer 驗收。

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

## MVP adapter commands

1. Notion connector 先輸出 normalized snapshot JSON，再執行 `scripts/patrol.sh`。
2. 用 `scripts/fingerprint.sh` 產生 requirement identity。
3. 用 `scripts/run-registry.sh start` 取得 lease；同一 fingerprint 的 active run 會被拒絕。
4. 每次實作 blocker 執行 `minimax-failure`；quota / rate-limit 只 resume MiniMax session，不增加 counter。
5. 第 3 次後執行 `run-registry.sh takeover`，只允許一次 ChatGPT takeover。
6. 用 `scripts/manifest.sh` 保存並驗證 evidence bundle。
7. 先執行 `scripts/release.sh preflight`，通過後才允許 push / PR / merge / deploy。

Normalized snapshot 最小格式：

```json
{"projects":[{"page_id":"...","name":"...","status":"開發中","spec_url":"...","github_url":"...","local_repo":"...","open_issues":0,"prod_http":200}]}
```
