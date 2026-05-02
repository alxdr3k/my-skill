# Handoff: agent workflow substrate

## Prompt

```text
Work in /Users/yngn/ws/my-skill.

Goal:
Explore and implement the smallest useful step toward a state-driven agent workflow substrate. The immediate target is not a new product or framework. It is to strengthen the existing my-skill workflow scripts so dev-cycle/codex-loop can emit structured, low-token, foreground-friendly workflow artifacts that DevDeck can later read as a projection layer.

Read first:
1. AGENTS.md
2. commands/dev-cycle.md
3. commands/codex-loop.md
4. scripts/dev-cycle-helper.sh
5. scripts/dev-cycle-helper/brief-state.sh
6. scripts/dev-cycle-helper/brief-render.sh
7. scripts/dev-cycle-helper/dispatch.sh
8. scripts/wait-codex-review.sh
9. tests/dev-cycle-helper-json.test.sh

Constraints:
- Do not run deploy.sh unless explicitly asked.
- Keep foreground-only execution. Do not introduce background polling, daemon behavior, queues, or watchers.
- Keep changes small and additive.
- Do not break existing command surfaces.
- Preserve current human stdout/Markdown behavior unless intentionally adding an optional structured mode.
- Treat JSONL as canonical machine state and Markdown/stdout as human projection.
- Any new schema must be tiny, versioned, and validated.
- If changing generated/deployed surfaces, consider commands/, codex/skills/, and .agents/scripts/ consistency.

Likely direction:
1. Inspect the existing dev-cycle JSON brief contract and tests.
2. Decide whether to introduce a small shared workflow event envelope, or keep the first change codex-loop-specific.
3. Prefer starting with codex-loop because it already has foreground polling and exit-code branching but lacks a structured observation artifact.
4. Consider adding an optional JSON observation mode to wait-codex-review.sh, for example CODEX_REVIEW_OUTPUT=json or --json.
5. The JSON observation should include repo, PR number, baseline, pass reaction state, feedback items, timeout state, review request / eyes acknowledgement state, API error classification, and next allowed action hints.
6. Add shell tests for the new structured behavior.
7. Report whether the result is enough for DevDeck to consume later as source state.

Do not implement a generic SDK, daemon, or DevDeck integration in this pass. The output of this task should be a narrow my-skill substrate improvement plus notes on the next slice.
```

## Context

This handoff comes from the second-brain ideation session:

- `/Users/yngn/ws/second-brain-idea-agent-json/Ideation/ai-agent-json-workflow-orchestration.md`

Current working conclusion:

- `my-skill` owns the execution semantics and structured workflow substrate.
- DevDeck remains a read-mostly projection layer for MVP.
- Future DevDeck execution should route through a foreground workflow runner rather than direct shell command ownership inside DevDeck.

## Non-goals

- No `deploy.sh`.
- No background daemon.
- No product shell.
- No DevDeck code changes in this task.
- No generic workflow SDK before one workflow slice proves the contract.
