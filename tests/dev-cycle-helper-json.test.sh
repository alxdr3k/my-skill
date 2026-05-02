#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$repo_root/scripts/dev-cycle-helper.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

new_repo() {
  local name="$1" dir
  dir="$tmp_root/$name"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test User"
  printf '%s\n' "$dir"
}

assert_rejects() {
  local label="$1"
  shift
  if "$@" >"$tmp_root/reject.out" 2>"$tmp_root/reject.err"; then
    echo "expected rejection: $label" >&2
    sed -n '1,40p' "$tmp_root/reject.out" >&2 || true
    return 1
  fi
}

bash -n "$helper"

repo_scope_docs="$(new_repo scope-docs)"
cd "$repo_scope_docs"
mkdir -p commands
printf '# Dev Cycle\n' > commands/dev-cycle.md
"$helper" change-scope > "$tmp_root/scope-docs.json"
jq -e '
  .kind == "dev_cycle_change_scope" and
  .change_scope.kind == "docs_only_contract" and
  .change_scope.review_required == true and
  .change_scope.contract_surface == true and
  .verification_profile.profile == "docs_contract" and
  .verification_profile.full_ci_required == false and
  (.review_inputs[] | select(.kind == "untracked_files" and (.files | index("commands/dev-cycle.md"))))
' "$tmp_root/scope-docs.json" >/dev/null

repo_scope_code="$(new_repo scope-code)"
cd "$repo_scope_code"
mkdir -p src
printf 'export const x = 1;\n' > src/index.ts
"$helper" change-scope > "$tmp_root/scope-code.json"
jq -e '
  .change_scope.kind == "code_or_runtime" and
  .verification_profile.profile == "full" and
  .verification_profile.full_ci_required == true
' "$tmp_root/scope-code.json" >/dev/null

repo_scope_standard="$(new_repo scope-standard)"
cd "$repo_scope_standard"
printf '# Base\n' > README.md
git add README.md
git commit -qm "base"
git switch -c feature -q
mkdir -p docs
printf 'committed\n' > docs/committed.md
git add docs/committed.md
git commit -qm "committed docs"
printf 'staged\n' > docs/staged.md
git add docs/staged.md
printf 'unstaged\n' >> README.md
printf 'untracked\n' > docs/untracked.md
"$helper" change-scope > "$tmp_root/scope-standard.json"
jq -e '
  .repo.type == "standard" and
  .review_base == "main" and
  .change_scope.kind == "docs_only_low_risk" and
  (.review_inputs[] | select(.kind == "base_range" and .command == "git diff main...HEAD" and (.files | index("docs/committed.md")))) and
  (.review_inputs[] | select(.kind == "staged_diff" and (.files | index("docs/staged.md")))) and
  (.review_inputs[] | select(.kind == "unstaged_diff" and (.files | index("README.md")))) and
  (.review_inputs[] | select(.kind == "untracked_files" and (.files | index("docs/untracked.md"))))
' "$tmp_root/scope-standard.json" >/dev/null

repo_dossier_standard="$(new_repo dossier-standard)"
cd "$repo_dossier_standard"
printf '# Base\n' > README.md
git add README.md
git commit -qm "base"
printf 'small doc update\n' >> README.md
"$helper" review-dossier > "$tmp_root/dossier-standard.json"
jq -e '
  .kind == "dev_cycle_review_dossier" and
  .change_scope.kind == "docs_only_low_risk" and
  .review_dossier.summary.changed_lines == 1 and
  .review_dossier.reviewer_route.recommended == "standard" and
  (.review_dossier.risk_triggers | length == 0)
' "$tmp_root/dossier-standard.json" >/dev/null

repo_dossier_untracked_no_newline="$(new_repo dossier-untracked-no-newline)"
cd "$repo_dossier_untracked_no_newline"
printf '# Base\n' > README.md
git add README.md
git commit -qm "base"
printf 'unterminated line' > docs.md
"$helper" review-dossier > "$tmp_root/dossier-untracked-no-newline.json"
jq -e '
  .kind == "dev_cycle_review_dossier" and
  .review_dossier.summary.untracked_text_lines == 1 and
  .review_dossier.summary.changed_lines == 1 and
  (.review_inputs[] | select(.kind == "untracked_files" and (.files | index("docs.md"))))
' "$tmp_root/dossier-untracked-no-newline.json" >/dev/null

repo_dossier_contract="$(new_repo dossier-contract)"
cd "$repo_dossier_contract"
mkdir -p commands
printf '# Command\n' > commands/example.md
"$helper" review-dossier > "$tmp_root/dossier-contract.json"
jq -e '
  .kind == "dev_cycle_review_dossier" and
  .change_scope.contract_surface == true and
  .review_dossier.reviewer_route.recommended == "opus_or_high_effort" and
  (.review_dossier.risk_triggers[] | select(.id == "contract_surface" and .severity == "high")) and
  (.review_dossier.risk_triggers[] | select(.id == "critical_paths" and (.evidence.paths | index("commands/example.md"))))
' "$tmp_root/dossier-contract.json" >/dev/null

repo_dossier_large="$(new_repo dossier-large)"
cd "$repo_dossier_large"
mkdir -p src
seq 1 401 > src/index.ts
"$helper" review-dossier > "$tmp_root/dossier-large.json"
jq -e '
  .kind == "dev_cycle_review_dossier" and
  .review_dossier.summary.changed_lines == 401 and
  .review_dossier.reviewer_route.recommended == "opus_or_high_effort" and
  (.review_dossier.risk_triggers[] | select(.id == "large_patch_over_400_lines" and .severity == "high"))
' "$tmp_root/dossier-large.json" >/dev/null

repo="$(new_repo ok)"
cd "$repo"
eval "$("$helper" init-brief)"
unset DEV_CYCLE_RUN_ID DEV_CYCLE_BRIEF_LOG DEV_CYCLE_BRIEF_JSONL DEV_CYCLE_RUN_JSON

"$helper" finish-cycle-json <<'JSON' > ack1.json
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "actions": [
    {"kind": "implement", "summary_ko": "JSON 브리핑 인터페이스를 구현했습니다."},
    {"kind": "verify", "summary_ko": "대표 입력을 검증했습니다."}
  ],
  "conclusion": {"summary_ko": "사이클 브리핑이 JSONL에 기록되고 Markdown으로 렌더링됩니다."},
  "changes": [{"path": "scripts/dev-cycle-helper.sh", "summary_ko": "finish-cycle-json 추가"}],
  "change_scope": {"kind": "docs_only_contract", "changed_files_count": 2, "contract_surface": true, "review_required": true},
  "verification_plan": {"profile": "docs_contract", "full_ci_required": false},
  "verification": [{"kind": "shell", "status": "pass", "summary_ko": "bash -n 통과"}],
  "review_land": {"status": "pushed", "summary_ko": "테스트 fixture에서는 원격 반영하지 않았습니다."},
  "next_candidates": [],
  "risks": []
}
JSON

"$helper" finish-cycle-json <<'JSON' > ack2.json
{
  "schema_version": 1,
  "cycle": 2,
  "result": "all_clear",
  "actions": [{"kind": "discover", "summary_ko": "roadmap/status를 확인해 다음 ready 작업을 찾았습니다."}],
  "conclusion": {"summary_ko": "현재 바로 진행할 ready 작업은 없습니다."},
  "changes": [],
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "상태 파일 확인 완료"}],
  "review_ship": {"status": "not_applicable", "summary_ko": "변경이 없어 PR을 만들지 않았습니다."},
  "next_candidates": [{"id": "AGENT-1A.1", "status": "planned", "summary_ko": "Config Agent 작업입니다.", "unblock_ko": "track 승격 필요"}],
  "auto_promotion_candidates": [
    {"id": "AGENT-1A.1", "status": "planned", "summary_ko": "Config Agent 작업입니다.", "eligible": true, "reason_ko": "선행 gate가 완료되어 ready로 승격할 수 있습니다."},
    {"id": "EXT-1A.1", "status": "planned", "summary_ko": "watch primitive 작업입니다.", "eligible": false, "reason_ko": "track 승격 결정이 필요합니다."}
  ],
  "auto_promotions": [
    {"id": "AGENT-1A.1", "status_before": "planned", "status_after": "ready", "summary_ko": "Config Agent 작업을 ready로 승격했습니다.", "path": "docs/04_IMPLEMENTATION_PLAN.md", "reason_ko": "선행 gate 완료"}
  ],
  "risks": []
}
JSON

jq -e '.cycle == 1 and (.rendered_markdown | contains("사이클 1 브리핑"))' ack1.json >/dev/null
jq -e '.cycle == 1 and .auto_promotions_count == 0' ack1.json >/dev/null
jq -e '.cycle == 1 and (.rendered_markdown | contains("반영 완료 (landed)") and contains("리뷰/반영") and contains("검증 계획"))' ack1.json >/dev/null
jq -e '.cycle == 1 and (.rendered_markdown | contains("배포") | not)' ack1.json >/dev/null
jq -e '.cycle == 2 and (.rendered_markdown | contains("다음 검토 후보"))' ack2.json >/dev/null
jq -e '.cycle == 2 and .result == "all_clear" and .auto_promotions_count == 1' ack2.json >/dev/null
jq -e '.cycle == 2 and (.rendered_markdown | contains("자동 승격 검토") and contains("EXT-1A.1") and contains("자동 승격 제외"))' ack2.json >/dev/null
jq -e '.cycle == 2 and (.rendered_markdown | contains("자동 승격") and contains("AGENT-1A.1") and contains("planned -> ready"))' ack2.json >/dev/null
test "$(wc -l < .dev-cycle/dev-cycle-briefs.jsonl | tr -d ' ')" = 2
"$helper" summary-json > summary.json
jq -e '.cycles | length == 2' summary.json >/dev/null
jq -e '.rendered_markdown | contains("최종 브리핑") and contains("사이클 1:") and contains("사이클 2:")' summary.json >/dev/null
jq -e '.rendered_markdown | contains("사이클 1: bash -n 통과") and contains("사이클 2: 상태 파일 확인 완료")' summary.json >/dev/null
jq -e '.rendered_markdown | contains("사이클 1: 테스트 fixture에서는 원격 반영하지 않았습니다.") and contains("사이클 2: 변경이 없어 PR을 만들지 않았습니다.")' summary.json >/dev/null
jq -e '.rendered_markdown | contains("리뷰/반영") and (contains("리뷰/배포") | not)' summary.json >/dev/null
jq -e '.auto_promotion_candidates | length == 2' summary.json >/dev/null
jq -e '.auto_promotions | length == 1' summary.json >/dev/null
jq -e '.rendered_markdown | contains("자동 승격 검토") and contains("사이클 2: EXT-1A.1")' summary.json >/dev/null
jq -e '.rendered_markdown | contains("자동 승격") and contains("사이클 2: AGENT-1A.1")' summary.json >/dev/null

assert_rejects "duplicate cycle" "$helper" finish-cycle-json <<'JSON'
{
  "schema_version": 1,
  "cycle": 2,
  "result": "all_clear",
  "actions": [{"kind": "discover", "summary_ko": "중복 테스트"}],
  "conclusion": {"summary_ko": "중복이어야 합니다."},
  "changes": [],
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "중복 검증"}],
  "review_ship": {"status": "not_applicable", "summary_ko": "없음"},
  "next_candidates": [],
  "risks": []
}
JSON

repo_gap="$(new_repo gap)"
cd "$repo_gap"
eval "$("$helper" init-brief)"
printf '## Cycle 1\n\n## Cycle 2\n\n## Cycle 3\n\n' >> .dev-cycle/dev-cycle-briefs.md
printf '%s\n' '{"cycle":1}' '{"cycle":3}' > .dev-cycle/dev-cycle-briefs.jsonl
assert_rejects "summary rejects non-contiguous JSONL" "$helper" summary-json
assert_rejects "non-contiguous JSONL" "$helper" finish-cycle-json <<'JSON'
{
  "schema_version": 1,
  "cycle": 4,
  "result": "all_clear",
  "actions": [{"kind": "discover", "summary_ko": "gap 테스트"}],
  "conclusion": {"summary_ko": "JSONL gap은 거부해야 합니다."},
  "changes": [],
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "gap fixture"}],
  "review_ship": {"status": "not_applicable", "summary_ko": "없음"},
  "next_candidates": [],
  "risks": []
}
JSON

repo_stale_env="$(new_repo stale-env)"
cd "$repo_stale_env"
eval "$("$helper" init-brief)"
export DEV_CYCLE_BRIEF_JSONL="$tmp_root/stale-env.jsonl"
"$helper" finish-cycle-json <<'JSON' > stale-env-ack.json
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "actions": [{"kind": "implement", "summary_ko": "stale env를 무시합니다."}],
  "conclusion": {"summary_ko": "JSONL은 현재 repo state path에 기록됩니다."},
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "state path 확인"}],
  "review_ship": {"status": "not_applicable", "summary_ko": "없음"},
  "next_candidates": [],
  "risks": []
}
JSON
test "$(wc -l < .dev-cycle/dev-cycle-briefs.jsonl | tr -d ' ')" = 1
test ! -e "$DEV_CYCLE_BRIEF_JSONL"
unset DEV_CYCLE_BRIEF_JSONL

stale_run_id="$DEV_CYCLE_RUN_ID"
stale_log="$DEV_CYCLE_BRIEF_LOG"
repo_stale_context="$(new_repo stale-context)"
cd "$repo_stale_context"
eval "$("$helper" init-brief)"
current_log="$DEV_CYCLE_BRIEF_LOG"
export DEV_CYCLE_RUN_ID="$stale_run_id"
export DEV_CYCLE_BRIEF_LOG="$stale_log"
"$helper" finish-cycle-json <<'JSON' > stale-context-ack.json
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "actions": [{"kind": "implement", "summary_ko": "stale run/log env를 무시합니다."}],
  "conclusion": {"summary_ko": "현재 repo의 .dev-cycle state를 사용합니다."},
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "state context 확인"}],
  "review_ship": {"status": "not_applicable", "summary_ko": "없음"},
  "next_candidates": [],
  "risks": []
}
JSON
grep -q "stale run/log env를 무시합니다." "$current_log"
test "$(wc -l < .dev-cycle/dev-cycle-briefs.jsonl | tr -d ' ')" = 1
unset DEV_CYCLE_RUN_ID DEV_CYCLE_BRIEF_LOG

repo_invalid="$(new_repo invalid)"
cd "$repo_invalid"
eval "$("$helper" init-brief)"
assert_rejects "empty actions" "$helper" finish-cycle-json <<'JSON'
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "actions": [],
  "conclusion": {"summary_ko": "invalid"},
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "x"}],
  "review_ship": {"status": "pushed"},
  "risks": []
}
JSON

assert_rejects "whitespace-only action summary" "$helper" finish-cycle-json <<'JSON'
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "actions": [{"kind": "implement", "summary_ko": "   "}],
  "conclusion": {"summary_ko": "invalid"},
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "x"}],
  "review_ship": {"status": "pushed"},
  "risks": []
}
JSON

assert_rejects "invalid auto promotion item" "$helper" finish-cycle-json <<'JSON'
{
  "schema_version": 1,
  "cycle": 1,
  "result": "all_clear",
  "actions": [{"kind": "discover", "summary_ko": "자동 승격 후보를 확인했습니다."}],
  "conclusion": {"summary_ko": "invalid"},
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "x"}],
  "review_ship": {"status": "not_applicable", "summary_ko": "없음"},
  "auto_promotions": [{}],
  "risks": []
}
JSON

assert_rejects "invalid auto promotion candidate eligible type" "$helper" finish-cycle-json <<'JSON'
{
  "schema_version": 1,
  "cycle": 1,
  "result": "all_clear",
  "actions": [{"kind": "discover", "summary_ko": "자동 승격 후보를 확인했습니다."}],
  "conclusion": {"summary_ko": "invalid"},
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "x"}],
  "review_ship": {"status": "not_applicable", "summary_ko": "없음"},
  "auto_promotion_candidates": [{"id": "BAD-1", "eligible": "false"}],
  "risks": []
}
JSON

assert_rejects "invalid change scope review_required type" "$helper" finish-cycle-json <<'JSON'
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "actions": [{"kind": "implement", "summary_ko": "변경 범위를 기록합니다."}],
  "conclusion": {"summary_ko": "invalid"},
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "x"}],
  "review_land": {"status": "pushed", "summary_ko": "없음"},
  "change_scope": {"kind": "docs_only", "review_required": "true"},
  "risks": []
}
JSON

assert_rejects "invalid verification plan full_ci_required type" "$helper" finish-cycle-json <<'JSON'
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "actions": [{"kind": "implement", "summary_ko": "검증 계획을 기록합니다."}],
  "conclusion": {"summary_ko": "invalid"},
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "x"}],
  "review_land": {"status": "pushed", "summary_ko": "없음"},
  "verification_plan": {"profile": "docs_only", "full_ci_required": "false"},
  "risks": []
}
JSON

repo_backfill="$(new_repo backfill)"
cd "$repo_backfill"
eval "$("$helper" init-brief)"
printf '## Cycle 1\n- Result: shipped\n- Work: legacy cycle\n- Verification: legacy verify\n- Review/Ship: legacy ship\n- Risk: none\n\n' >> .dev-cycle/dev-cycle-briefs.md
"$helper" finish-cycle-json <<'JSON' > backfill-ack.json
{
  "schema_version": 1,
  "cycle": 2,
  "result": "all_clear",
  "actions": [{"kind": "discover", "summary_ko": "mismatch"}],
  "conclusion": {"summary_ko": "mismatch"},
  "verification": [{"kind": "status", "status": "pass", "summary_ko": "mismatch"}],
  "review_ship": {"status": "not_applicable", "summary_ko": "mismatch"},
  "next_candidates": [],
  "risks": []
}
JSON
jq -e '.cycle == 2' backfill-ack.json >/dev/null
test "$(wc -l < .dev-cycle/dev-cycle-briefs.jsonl | tr -d ' ')" = 2
jq -e 'select(.cycle == 1 and .actions[0].kind == "legacy_markdown")' .dev-cycle/dev-cycle-briefs.jsonl >/dev/null

repo_risk="$(new_repo risk)"
cd "$repo_risk"
mkdir -p bin
printf '#!/usr/bin/env bash\necho fake gh failure >&2\nexit 1\n' > bin/gh
chmod +x bin/gh
eval "$(PATH="$repo_risk/bin:$PATH" "$helper" init-brief)"
PATH="$repo_risk/bin:$PATH" "$helper" finish-cycle-json <<'JSON' > ack-risk.json 2> risk.err
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "actions": [{"kind": "land", "summary_ko": "변경을 push했습니다."}],
  "conclusion": {"summary_ko": "작업은 반영됐고 남은 리스크를 기록합니다."},
  "changes": [],
  "verification": [{"kind": "test", "status": "pass", "summary_ko": "대표 테스트 통과"}],
  "review_land": {"status": "pushed", "summary_ko": "main에 push 완료"},
  "next_candidates": [],
  "risks": [
    {"summary_ko": "후속 결선 리스크", "next_action_ko": "다음 cycle에서 처리"},
    {"summary_ko": "관찰 환경 리스크", "next_action_ko": "외부 입력 확인"}
  ]
}
JSON
jq -e '.result == "landed"' ack-risk.json >/dev/null
jq -e '(.risks | length == 2) and all(.risks[]; .issue_error == "fake gh failure")' .dev-cycle/dev-cycle-briefs.jsonl >/dev/null

repo_risk_success="$(new_repo risk-success)"
cd "$repo_risk_success"
mkdir -p bin
printf '#!/usr/bin/env bash\necho https://github.example/issues/1\n' > bin/gh
chmod +x bin/gh
eval "$(PATH="$repo_risk_success/bin:$PATH" "$helper" init-brief)"
PATH="$repo_risk_success/bin:$PATH" "$helper" finish-cycle-json <<'JSON' > ack-risk-success.json
{
  "schema_version": 1,
  "cycle": 1,
  "result": "landed",
  "actions": [{"kind": "land", "summary_ko": "변경을 push했습니다."}],
  "conclusion": {"summary_ko": "작업은 반영됐고 남은 리스크를 이슈로 기록합니다."},
  "changes": [],
  "verification": [{"kind": "test", "status": "pass", "summary_ko": "대표 테스트 통과"}],
  "review_land": {"status": "pushed", "summary_ko": "main에 push 완료"},
  "next_candidates": [],
  "risks": [{"summary_ko": "후속 결선 리스크", "next_action_ko": "다음 cycle에서 처리"}]
}
JSON
jq -e '.risks[0].issue_url == "https://github.example/issues/1"' .dev-cycle/dev-cycle-briefs.jsonl >/dev/null
jq -e '.rendered_markdown | contains("리스크 이슈 생성") and contains("https://github.example/issues/1")' ack-risk-success.json >/dev/null
"$helper" summary-json > summary-risk-success.json
jq -e '.rendered_markdown | contains("사이클 1: 후속 결선 리스크") and contains("https://github.example/issues/1")' summary-risk-success.json >/dev/null

repo_summary_backfill="$(new_repo summary-backfill)"
cd "$repo_summary_backfill"
eval "$("$helper" init-brief)"
printf '## Cycle 1\n- Result: shipped\n- Work: legacy work\n- Verification: legacy verify\n- Review/Ship: legacy ship\n- Risk: none\n\n' >> .dev-cycle/dev-cycle-briefs.md
"$helper" summary-json > legacy-summary.json
jq -e '.cycles | length == 1' legacy-summary.json >/dev/null
jq -e '.cycles[0].headline_ko == "legacy work"' legacy-summary.json >/dev/null

repo_legacy="$(new_repo legacy)"
cd "$repo_legacy"
eval "$("$helper" init-brief)"
DEV_CYCLE_CYCLE=1 \
DEV_CYCLE_RESULT="ALL CLEAR" \
DEV_CYCLE_WORK="roadmap/status를 확인했고 ready 작업이 없다고 판단했습니다." \
DEV_CYCLE_VERIFICATION="sync clean" \
DEV_CYCLE_REVIEW_SHIP="변경 없음" \
DEV_CYCLE_RISK="없음" \
"$helper" finish-cycle >"$tmp_root/legacy.out"
jq -e '.cycle == 1 and .actions[0].kind == "legacy"' .dev-cycle/dev-cycle-briefs.jsonl >/dev/null

echo "dev-cycle JSON briefing workflow tests passed"
