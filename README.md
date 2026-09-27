# autonomous-dev-orchestrator

Notion-driven autonomous development controller for Sean's workspace.

這個專案負責「巡視、鎖定、派工、計數、證據、release gate、Notion 同步」；實際的 Planner / Developer / QA / Integrator / Final Reviewer 執行仍沿用 workspace 的 [`autonomous-dev-agent`](../../autonomous-dev-agent/README.md)。

## Policy

- MiniMax 以 pinned `mcode` CLI 執行。
- 同一 requirement 最多 3 個 MiniMax implementation cycle。
- 第 3 次仍失敗才由 ChatGPT Developer 接手。
- ChatGPT 接手後仍需獨立 QA 與 Final Review。
- 自動 push、PR、merge、production deploy 已啟用；高風險變更仍需人審。

## 驗證

```bash
bash scripts/quality-gate.sh
```

## 文件

- [`PRD/SPEC.md`](PRD/SPEC.md)：功能需求、AC、ADR
- [`SOP.md`](SOP.md)：執行與 release 流程
- [`AGENTS.md`](AGENTS.md)：agent 權限與專案不變量
- [`config/orchestrator.json`](config/orchestrator.json)：機器可讀政策
