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

## MVP 操作入口

將 Notion connector 正規化成 snapshot JSON 後巡視：

```bash
bash scripts/patrol.sh /absolute/path/to/notion-snapshot.json
```

建立 requirement fingerprint 與 run lease：

```bash
FINGERPRINT="$(bash scripts/fingerprint.sh <project-page-id> <spec-revision> <next-action> <open-issues> <ac-hash>)"
RUN_ID="$(bash scripts/run-registry.sh start <project-page-id> "$FINGERPRINT" /absolute/path/to/repo)"
```

每個需求的完整 MiniMax cycle 失敗後執行 `minimax-failure`；第三次後才能執行 `takeover`。所有證據完成後用 `manifest.sh verify`，再進入 `release.sh preflight`。

`release.sh` 對 GitHub、Vercel、smoke test 與 rollback 採 fail-closed；缺少 remote、CLI、token 或 required evidence 時會停止，不會宣告成功。

執行既有 autonomous-dev-agent cycle：

```bash
bash scripts/dispatch.sh <project-page-id> <fingerprint> /absolute/path/to/repo /absolute/path/to/GOAL.md
```

controller 會依序執行 3 個 MiniMax cycle；第三次仍失敗才切到 ChatGPT Developer。每輪失敗會建立 checkpoint commit，讓下一輪維持 clean worktree；quota / rate-limit exhausted 則直接 blocked，不會錯誤觸發 ChatGPT fallback。

## 文件

- [`PRD/SPEC.md`](PRD/SPEC.md)：功能需求、AC、ADR
- [`SOP.md`](SOP.md)：執行與 release 流程
- [`AGENTS.md`](AGENTS.md)：agent 權限與專案不變量
- [`config/orchestrator.json`](config/orchestrator.json)：機器可讀政策
