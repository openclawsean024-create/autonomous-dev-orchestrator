# Autonomous Dev Orchestrator — PRD / SPEC

版本：v0.1 · 日期：2026-09-27 · 狀態：規格中

## 1. 目標

建立一個可恢復、可追溯、以 Notion canonical Project DB 為入口的全自動開發控制器：巡視專案、建立 bounded goal、派送 MiniMax、由 ChatGPT 執行獨立驗收；同一需求連續 3 個 MiniMax implementation cycle 未通過後，才由 ChatGPT 接手 Developer 工作。

## 2. 非目標

- 不建立第二個 Notion Project DB。
- 不讓 agent 自行修改 branch protection 或 rotate secrets。
- 不以模型口頭宣稱取代測試輸出、exit code、QA 與 Final Review。
- 不把 quota / rate-limit recovery 當成需求品質失敗。
- 不在本專案內重寫既有 `autonomous-dev-agent` role runner；本專案提供巡視、狀態、計數、release orchestration。

## 3. 流程狀態

```text
待巡視 → 可開發 → 已鎖定 → 規劃中 → MiniMax 開發中
→ 確定性檢查 → Codex QA → MiniMax 修復
→ ChatGPT 接手 → 最終驗收 → 已完成
                                      ↘ 阻塞 / 需人審
```

## 4. 功能需求

### FR-001 Notion patrol

控制器週期性讀取唯一 canonical Project DB，篩選非終態、具備 SPEC、GitHub URL、可定位本地 repo 且未被其他 run lock 的專案。既有預設巡視週期為 6 小時。

### FR-002 Requirement fingerprint

每次 run 必須由 project page ID、SPEC revision、Next Action、Open Issues 與必要 acceptance criteria 產生穩定 fingerprint。fingerprint 未變更時不得重複建立相同 run。

### FR-003 Lease / idempotency

run 必須有 `active_run_id`、lease owner、lease expiry、heartbeat 與 last processed fingerprint。controller 重啟後可接續未過期 run；過期 run 必須先標記為 interrupted，再建立新的 run。

### FR-004 MiniMax cycle policy

每個 requirement 最多 3 個 MiniMax implementation cycle。每個 cycle 必須包含：approved plan、workspace write、deterministic gate、Codex QA；QA 不通過時由 MiniMax Integrator 修復並重新驗證。

### FR-005 ChatGPT fallback

第 3 個 MiniMax cycle 仍未取得完整 PASS 時，controller 將同一 evidence bundle 與最後一份 QA blocker 交給 ChatGPT Developer。ChatGPT 只能接手一次；接手後仍須走完整獨立驗收鏈。

### FR-006 Failure taxonomy

系統至少區分：`quota`、`rate_limit`、`transient_network`、`auth_or_harness`、`test_failure`、`spec_ambiguity`、`security_risk`、`concurrency_conflict`。只有 `test_failure` / 實作 blocker 會增加 MiniMax cycle count。

### FR-007 Evidence

每個 run 保存 task、plan、logs、diff、test exit code、QA verdict、final-review verdict、commit SHA、PR URL、merge SHA、deployment SHA、smoke test 結果與 Notion sync 結果。

### FR-008 Release automation

在所有 acceptance criteria、deterministic checks、QA、Final Review、required checks 與風險門檻通過後，允許自動 push、開 PR、merge、production deploy。deploy 後 60 秒內 HTTP 非 200 必須 rollback 並通知 Sean。

### FR-009 Human gates

涉及 DB migration、auth、payments、secrets、infra deletion 或 branch protection 時，自動化必須轉 `需人審`，不可只因 ChatGPT fallback 而繞過。

### FR-010 Notion synchronization

成功 release 必須把狀態、HEAD SHA、GitHub URL、Vercel URL、Prod HTTP、Next Action 與 evidence URL 同步回 canonical Project DB；任一同步失敗時不得宣告 release 完成。

## 5. Acceptance Criteria

- AC-001：沒有 SPEC、GitHub URL 或本地 repo 時不派工，狀態為 `blocked`。
- AC-002：同一 fingerprint 在 lease 有效期間只建立一個 active run。
- AC-003：MiniMax quota / 429 retry 不增加 implementation cycle count。
- AC-004：三個完整 MiniMax cycle 失敗後才進入 ChatGPT Developer fallback。
- AC-005：ChatGPT fallback 完成後，QA 與 Final Reviewer 仍為 read-only 且獨立執行。
- AC-006：任何 gate 失敗都保留 exit code 與原始輸出，不得只記錄模型摘要。
- AC-007：高風險變更沒有 `risk-approved` + Sean 人審時，流程停在 `需人審`。
- AC-008：merge 前必須有 deterministic PASS、QA PASS、Final Review PASS 與 required checks PASS。
- AC-009：production smoke test 非 200 時執行 rollback，且 Notion 狀態不得寫成已上線。
- AC-010：成功 release 後 GitHub HEAD、Vercel production SHA、Notion HEAD SHA 與 local HEAD 可驗證一致。

## 6. 建議 Notion 欄位

沿用 canonical Project DB；新增流程欄位時不得另建 Project DB：`Automation Status`、`Current Requirement`、`Attempt Count`、`Last Run ID`、`Last Failure Type`、`Retry At`、`Risk Tier`、`Human Approval Required`、`Evidence URL`、`Current Branch / PR`。

## 7. ADR

### ADR-001：三次計數以完整 implementation cycle 為單位

理由：避免把同一個 quota retry、單次 QA、或網路重試誤算成需求品質失敗。

### ADR-002：fallback 後仍由獨立 reviewer 驗收

理由：Developer 與驗收者必須分離，ChatGPT 接手不代表自動通過。

### ADR-003：先建立 evidence 再同步 Notion

理由：Notion 是狀態索引，不是測試證據本身；所有狀態必須可回溯到 immutable run evidence。
