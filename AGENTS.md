# AGENTS.md — Autonomous Dev Orchestrator

## 1. 規格來源

本專案以 [`PRD/SPEC.md`](./PRD/SPEC.md) 為 single source of truth。流程政策與執行命令分別見 [`SOP.md`](./SOP.md) 與 [`config/orchestrator.json`](./config/orchestrator.json)。

## 2. 專案不變量

- 只巡視 workspace canonical Notion Project DB，不建立第二個 Project DB。
- 同一個 `project + requirement fingerprint` 同時只能有一個 active run。
- MiniMax 失敗計數以「完整 implementation cycle」計算，最多 3 次；quota / rate-limit / 暫時性網路錯誤不計入。
- 第 3 次 MiniMax cycle 仍未通過，才允許 ChatGPT 取得 Developer 寫入權限。
- ChatGPT 接手後仍必須經過 deterministic checks、獨立 QA、Final Reviewer；Developer 不得自我驗收。
- 每個 run 必須保留不可變證據：plan、diff、測試輸出、QA、final review、commit SHA、deployment SHA。
- 不得印出或寫入 token、cookie、`.env`、connection string 或其他 secret。

## 3. 自動化授權

本專案允許自動：

- push branch / main
- 建立與更新 Pull Request
- 在 required checks、QA、Final Review 及 branch protection 通過後 merge
- 在 production deploy gate 通過後部署
- deploy 後執行 60 秒 HTTP smoke test；失敗時 rollback 至前一個 stable deployment 並通知 Sean

仍然必須停在人審：

- DB migration
- authentication / authorization
- payments / billing
- secrets rotation
- infrastructure deletion
- branch protection 變更

上述風險項目必須同時具備 `risk-approved` label 與 Sean 人審；自動化權限不等於跳過風險門檻。

## 4. Agent 權限

| Role | 寫入 workspace | 允許 push / PR / merge / deploy |
|---|---:|---:|
| Planner | 否 | 否 |
| MiniMax Developer | 是 | 由 Integrator / release controller 執行 |
| Codex QA | 否 | 否 |
| MiniMax Integrator | 是 | 可依 release gate 執行 |
| ChatGPT Developer fallback | 是 | 由 Integrator / release controller 執行 |
| Final Reviewer | 否 | 否 |

MiniMax 必須透過 pinned `mcode` CLI；不得改用 MiniMax Desktop app。

## 5. 驗證命令

```bash
bash scripts/quality-gate.sh
```

此專案目前的 deterministic gate 會驗證流程設定、狀態轉移與 MiniMax 三次 fallback policy。實際目標 repo 的 build、lint、typecheck、unit、integration、E2E 仍由該 repo 自己的 `AGENTS.md` 定義。

## 6. 禁止事項

- 不得因 QA 失敗而刪除或弱化測試。
- 不得因 Notion 暫時不可用而宣告 release 完成。
- 不得將 quota retry 當成需求失敗計數。
- 不得在缺少 SPEC、GitHub URL、clean worktree 或明確 acceptance criteria 時自動開發。
- 不得讓同一個 requirement 在沒有新 evidence 或 plan revision 的情況下無限重試。
