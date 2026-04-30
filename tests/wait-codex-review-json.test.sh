#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$repo_root/scripts/wait-codex-review.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/bin"
cat > "$tmp_root/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

scenario="${GH_SCENARIO:-pass}"

if [[ "${1:-}" != "api" ]]; then
  echo "unsupported gh command: $*" >&2
  exit 1
fi

if [[ "${2:-}" == "user" ]]; then
  echo "me"
  exit 0
fi

paginate=false
if [[ "${2:-}" == "--paginate" ]]; then
  paginate=true
  endpoint="${3:-}"
  shift 3
else
  endpoint="${2:-}"
  shift 2
fi

if [[ "$paginate" == false && "$endpoint" == "repos/o/r/issues/1/comments" ]]; then
  echo '{"id":100,"body":"@codex review"}'
  exit 0
fi

case "$endpoint" in
  repos/o/r/issues/1/reactions)
    if [[ "$scenario" == "permanent" ]]; then
      echo "HTTP 403: forbidden" >&2
      exit 1
    fi
    if [[ "$scenario" == "pass" ]]; then
      cat <<'JSON'
[{"content":"+1","created_at":"2026-01-01T00:01:00Z","user":{"login":"chatgpt-codex-connector[bot]"}}]
JSON
    else
      echo '[]'
    fi
    ;;
  repos/o/r/issues/1/comments)
    if [[ "$scenario" == "feedback" ]]; then
      cat <<'JSON'
[{"created_at":"2026-01-01T00:02:00Z","body":"please fix this","user":{"login":"reviewer"},"reactions":{"eyes":0}}]
JSON
    else
      echo '[]'
    fi
    ;;
  repos/o/r/pulls/1/reviews|repos/o/r/pulls/1/comments)
    echo '[]'
    ;;
  *)
    echo "unexpected endpoint: $endpoint" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$tmp_root/bin/gh"

run_json() {
  local scenario="$1" out="$2" err="$3" rc
  set +e
  PATH="$tmp_root/bin:$PATH" \
    GH_SCENARIO="$scenario" \
    CODEX_REVIEW_OUTPUT=json \
    CODEX_REPO=o/r \
    CODEX_BASELINE=2026-01-01T00:00:00Z \
    CODEX_POLL_INTERVAL=0 \
    CODEX_INITIAL_EMPTY_DELAY=0 \
    CODEX_POLL_TIMEOUT=5 \
    "$helper" 1 > "$out" 2> "$err"
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

bash -n "$helper"

missing_out="$tmp_root/missing.json"
missing_err="$tmp_root/missing.err"
set +e
PATH="$tmp_root/bin:$PATH" CODEX_REVIEW_OUTPUT=json "$helper" > "$missing_out" 2> "$missing_err"
missing_rc=$?
set -e
test "$missing_rc" = 3
jq -e '
  .result == "pr_not_detected" and
  .exit_code == 3 and
  .pr_number == null and
  (.next_allowed_actions | index("rerun_with_pr_number_or_url"))
' "$missing_out" >/dev/null

pass_out="$tmp_root/pass.json"
pass_err="$tmp_root/pass.err"
test "$(run_json pass "$pass_out" "$pass_err")" = 0
test "$(wc -l < "$pass_out" | tr -d ' ')" = 1
jq -e '
  .schema_version == 1 and
  .kind == "codex_review_observation" and
  .result == "passed" and
  .exit_code == 0 and
  .repo == "o/r" and
  .pr_number == 1 and
  .baseline == "2026-01-01T00:00:00Z" and
  .pass_reaction.observed == true and
  (.next_allowed_actions | index("merge_pr")) and
  .api.error_class == null
' "$pass_out" >/dev/null

cli_out="$tmp_root/cli.json"
cli_err="$tmp_root/cli.err"
set +e
PATH="$tmp_root/bin:$PATH" \
  GH_SCENARIO=pass \
  CODEX_REPO=o/r \
  CODEX_BASELINE=2026-01-01T00:00:00Z \
  CODEX_POLL_INTERVAL=0 \
  CODEX_INITIAL_EMPTY_DELAY=0 \
  CODEX_POLL_TIMEOUT=5 \
  "$helper" --json 1 > "$cli_out" 2> "$cli_err"
cli_rc=$?
set -e
test "$cli_rc" = 0
jq -e '.result == "passed" and .pr_number == 1' "$cli_out" >/dev/null

feedback_out="$tmp_root/feedback.json"
feedback_err="$tmp_root/feedback.err"
test "$(run_json feedback "$feedback_out" "$feedback_err")" = 1
jq -e '
  .result == "feedback" and
  .exit_code == 1 and
  (.feedback_items | length) == 1 and
  .feedback_items[0].kind == "issue_comment" and
  .feedback_items[0].body == "please fix this" and
  (.next_allowed_actions | index("apply_feedback"))
' "$feedback_out" >/dev/null

human_out="$tmp_root/human.out"
human_err="$tmp_root/human.err"
set +e
PATH="$tmp_root/bin:$PATH" \
  GH_SCENARIO=feedback \
  CODEX_REPO=o/r \
  CODEX_BASELINE=2026-01-01T00:00:00Z \
  CODEX_POLL_INTERVAL=0 \
  CODEX_INITIAL_EMPTY_DELAY=0 \
  CODEX_POLL_TIMEOUT=5 \
  "$helper" 1 > "$human_out" 2> "$human_err"
human_rc=$?
set -e
test "$human_rc" = 1
grep -q '=== \[issue_comment\] reviewer @ 2026-01-01T00:02:00Z ===' "$human_out"
grep -q 'please fix this' "$human_out"

unacked_out="$tmp_root/unacked.json"
unacked_err="$tmp_root/unacked.err"
test "$(run_json empty "$unacked_out" "$unacked_err")" = 2
jq -e '
  .result == "review_request_unacknowledged" and
  .exit_code == 2 and
  .review_request.posted == true and
  .review_request.acknowledged == false and
  .review_request.polls_after_post == 3 and
  (.next_allowed_actions | index("stop_loop"))
' "$unacked_out" >/dev/null

permanent_out="$tmp_root/permanent.json"
permanent_err="$tmp_root/permanent.err"
test "$(run_json permanent "$permanent_out" "$permanent_err")" = 4
jq -e '
  .result == "api_error" and
  .exit_code == 4 and
  .api.error_class == "permanent" and
  .api.label == "reactions" and
  (.next_allowed_actions | index("check_auth_or_permissions"))
' "$permanent_out" >/dev/null

echo "wait-codex-review JSON observation tests passed"
