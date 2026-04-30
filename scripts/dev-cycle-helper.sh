#!/usr/bin/env bash
# Shared helpers for dev-cycle commands/skills.

set -euo pipefail

script_dir() {
  local source dir
  source="${BASH_SOURCE[0]}"
  while [[ -L "$source" ]]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" && pwd
}

direct_push_list_file() {
  local dir candidate
  dir="$(script_dir)"
  for candidate in "$dir/direct-push-repos.txt" "$dir/../direct-push-repos.txt"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  echo "Missing direct-push-repos.txt next to dev-cycle-helper.sh" >&2
  return 1
}

direct_push_repos() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^[[:space:]]*$/d; /^#/d' "$(direct_push_list_file)"
}

repo_root() {
  git rev-parse --show-toplevel
}

repo_name() {
  local remote name
  remote="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "$remote" ]]; then
    remote="${remote%.git}"
    name="${remote##*/}"
    [[ "$remote" == *:* && "$remote" != http* ]] && name="${remote##*:}"
    name="${name##*/}"
    if [[ -n "$name" ]]; then
      printf '%s\n' "$name"
      return
    fi
  fi
  basename "$(repo_root)"
}

repo_type() {
  local name
  name="$(repo_name)"
  if direct_push_repos | grep -qxF "$name"; then
    echo "direct-push"
  else
    echo "standard"
  fi
}

default_branch() {
  local branch
  branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  if [[ -z "$branch" ]]; then
    branch="$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' || true)"
  fi
  echo "${branch:-main}"
}

review_base() {
  if [[ "$(repo_type)" == "direct-push" ]]; then
    echo "main"
    return
  fi

  local base
  base="$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || true)"
  if [[ -n "$base" ]]; then
    echo "$base"
  elif git show-ref --verify --quiet refs/remotes/origin/dev; then
    echo "dev"
  else
    default_branch
  fi
}

sync_repo() {
  local current type default
  current="$(git branch --show-current)"
  type="$(repo_type)"
  default="$(default_branch)"

  git fetch origin

  if [[ -z "$current" ]]; then
    echo "Detached HEAD: cannot run dev-cycle sync safely" >&2
    return 1
  fi

  if [[ "$type" == "direct-push" ]]; then
    if [[ "$current" != "main" && -n "$(git status --porcelain)" ]]; then
      echo "Dirty worktree on $current: cannot switch direct-push repo to main safely" >&2
      return 1
    fi
    if [[ "$current" == "main" && -n "$(git status --porcelain)" ]]; then
      echo "Dirty worktree on main: commit, stash, or clean before direct-push sync" >&2
      return 1
    fi
    git switch main
    git pull --ff-only origin main
    return
  fi

  if git show-ref --verify --quiet refs/remotes/origin/dev; then
    if [[ "$current" == "dev" ]]; then
      git pull --ff-only origin dev
    elif [[ -z "$(git status --porcelain)" ]]; then
      git switch dev
      git pull --ff-only origin dev
      git switch "$current"
    else
      echo "Dirty worktree: fetched origin/dev, skipped local dev checkout" >&2
    fi
  elif [[ "$current" == "$default" ]]; then
    git pull --ff-only origin "$default"
  fi
}

ensure_state_dir() {
  local root git_dir state_dir exclude_file
  root="$(repo_root)"
  git_dir="$(git rev-parse --git-dir)"
  state_dir="$root/.dev-cycle"
  exclude_file="$git_dir/info/exclude"

  mkdir -p "$state_dir"
  if [[ -f "$exclude_file" ]]; then
    grep -qxF ".dev-cycle/" "$exclude_file" 2>/dev/null || echo ".dev-cycle/" >> "$exclude_file"
  fi
  echo "$state_dir"
}

shell_export() {
  local key="$1" value="$2"
  printf 'export %s=%q\n' "$key" "$value"
}

brief_run_id_file() {
  local state_dir="$1"
  printf '%s\n' "$state_dir/dev-cycle-run-id"
}

brief_start_epoch_file() {
  local state_dir="$1"
  printf '%s\n' "$state_dir/dev-cycle-start-epoch"
}

format_duration() {
  local total="$1" days hours minutes seconds parts
  (( total < 0 )) && total=0
  days=$((total / 86400))
  hours=$(((total % 86400) / 3600))
  minutes=$(((total % 3600) / 60))
  seconds=$((total % 60))

  parts=()
  if (( days > 0 )); then parts+=("${days}d"); fi
  if (( hours > 0 )); then parts+=("${hours}h"); fi
  if (( minutes > 0 )); then parts+=("${minutes}m"); fi
  if (( seconds > 0 || ${#parts[@]} == 0 )); then parts+=("${seconds}s"); fi
  printf '%s\n' "${parts[*]}"
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for dev-cycle JSON brief handling" >&2
    return 1
  fi
}

brief_jsonl_file() {
  local state_dir="$1"
  printf '%s\n' "$state_dir/dev-cycle-briefs.jsonl"
}

brief_run_json_file() {
  local state_dir="$1"
  printf '%s\n' "$state_dir/dev-cycle-run.json"
}

init_brief() {
  local run_id started_at start_epoch state_dir log jsonl run_json run_id_file start_epoch_file
  require_jq || return 1
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  started_at="$(iso_now)"
  start_epoch="$(date -u +%s)"
  state_dir="$(ensure_state_dir)"
  log="$state_dir/dev-cycle-briefs.md"
  jsonl="$(brief_jsonl_file "$state_dir")"
  run_json="$(brief_run_json_file "$state_dir")"
  run_id_file="$(brief_run_id_file "$state_dir")"
  start_epoch_file="$(brief_start_epoch_file "$state_dir")"
  printf "# Dev Cycle Briefs %s\n\n" "$run_id" > "$log" || return 1
  : > "$jsonl" || return 1
  jq -n \
    --arg run_id "$run_id" \
    --arg started_at "$started_at" \
    --arg repo "$(repo_name)" \
    --arg repo_type "$(repo_type)" \
    --arg root "$(repo_root)" \
    '{schema_version:1, run_id:$run_id, started_at:$started_at, repo:{name:$repo, type:$repo_type, root:$root}}' \
    > "$run_json" || return 1
  printf '%s\n' "$run_id" > "$run_id_file" || return 1
  printf '%s\n' "$start_epoch" > "$start_epoch_file" || return 1
  shell_export DEV_CYCLE_RUN_ID "$run_id"
  shell_export DEV_CYCLE_BRIEF_LOG "$log"
  shell_export DEV_CYCLE_BRIEF_JSONL "$jsonl"
  shell_export DEV_CYCLE_RUN_JSON "$run_json"
}

validate_brief() {
  local run_id="${1:-}" log="${2:-}" first
  [[ -n "$run_id" && -n "$log" && -f "$log" ]] || return 1
  first="$(head -n 1 "$log")"
  [[ "$first" == "# Dev Cycle Briefs $run_id" ]]
}

brief_context() {
  local state_dir run_id_file run_id log
  state_dir="$(ensure_state_dir)"
  run_id_file="$(brief_run_id_file "$state_dir")"
  run_id=""
  log="$state_dir/dev-cycle-briefs.md"

  if [[ -f "$run_id_file" ]]; then
    run_id="$(sed -n '1p' "$run_id_file")"
  fi

  if ! validate_brief "$run_id" "$log"; then
    echo "No valid dev-cycle brief state. Run init-brief at the start of this dev-cycle run." >&2
    return 1
  fi

  printf '%s\n%s\n' "$run_id" "$log"
}

validate_cycle_append() {
  local cycle="$1" log="$2" previous

  if grep -Eq "^(## Cycle $cycle|사이클 $cycle 브리핑)$" "$log"; then
    echo "Cycle $cycle is already recorded in $log" >&2
    return 1
  fi

  if [[ "$cycle" =~ ^[0-9]+$ ]]; then
    if (( cycle == 1 )); then
      if grep -Eq '^(## Cycle |사이클 [0-9]+ 브리핑$)' "$log"; then
        echo "Brief log already contains cycles; run init-brief to start a new dev-cycle run." >&2
        return 1
      fi
    elif (( cycle > 1 )); then
      previous=$((cycle - 1))
      if ! grep -Eq "^(## Cycle $previous|사이클 $previous 브리핑)$" "$log"; then
        echo "Brief log is missing Cycle $previous before Cycle $cycle" >&2
        return 1
      fi
    fi
  fi
}

validate_jsonl_state() {
  local jsonl="$1"
  [[ -s "$jsonl" ]] || return 0

  if ! jq -e -s '
    all(.[]; ((.cycle | type) == "number") and (.cycle >= 1) and (.cycle == (.cycle | floor)))
  ' "$jsonl" >/dev/null; then
    echo "Brief JSONL is invalid or contains records without numeric cycle: $jsonl" >&2
    return 1
  fi

  if ! jq -e -s '
    ([.[].cycle] | sort) as $cycles |
    $cycles == [range(1; ($cycles | length) + 1)]
  ' "$jsonl" >/dev/null; then
    echo "Brief JSONL has non-contiguous cycle records: $jsonl" >&2
    return 1
  fi
}

validate_jsonl_append() {
  local cycle="$1" jsonl="$2" previous

  if [[ ! "$cycle" =~ ^[0-9]+$ ]]; then
    echo "Cycle must be numeric for JSONL append validation" >&2
    return 1
  fi

  validate_jsonl_state "$jsonl" || return 1

  if jq -e --argjson cycle "$cycle" 'select(.cycle == $cycle)' "$jsonl" >/dev/null 2>&1; then
    echo "Cycle $cycle is already recorded in $jsonl" >&2
    return 1
  fi

  if (( cycle == 1 )); then
    if [[ -s "$jsonl" ]]; then
      echo "Brief JSONL already contains cycles; run init-brief to start a new dev-cycle run." >&2
      return 1
    fi
  elif (( cycle > 1 )); then
    previous=$((cycle - 1))
    if ! jq -e --argjson previous "$previous" 'select(.cycle == $previous)' "$jsonl" >/dev/null 2>&1; then
      echo "Brief JSONL is missing Cycle $previous before Cycle $cycle. Run init-brief for a new run or repair the JSONL from the existing brief state." >&2
      return 1
    fi
  fi
}

backfill_jsonl_from_markdown_if_needed() {
  local log="$1" jsonl="$2" run_id="$3" repo repo_type branch head_sha tmp
  [[ ! -s "$jsonl" ]] || return 0
  grep -Eq '^(## Cycle [0-9]+|사이클 [0-9]+ 브리핑)$' "$log" || return 0

  repo="$(repo_name)"
  repo_type="$(repo_type)"
  branch="$(git branch --show-current 2>/dev/null || true)"
  head_sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  tmp="$(mktemp)" || return 1

  if ! awk '
    BEGIN { sep = sprintf("%c", 28) }
    function flush() {
      if (cycle != "") {
        print cycle sep result sep work sep conclusion sep verification sep review sep risk
      }
    }
    function reset() {
      result = ""; work = ""; conclusion = ""; verification = ""; review = ""; risk = ""
    }
    /^## Cycle [0-9]+$/ {
      flush(); reset(); cycle = $3; next
    }
    /^사이클 [0-9]+ 브리핑$/ {
      flush(); reset(); cycle = $2; next
    }
    cycle != "" && /^- Result: / { sub(/^- Result: /, ""); result = $0; next }
    cycle != "" && /^- Work: / { sub(/^- Work: /, ""); work = $0; next }
    cycle != "" && /^- Verification: / { sub(/^- Verification: /, ""); verification = $0; next }
    cycle != "" && /^- Review\/Ship: / { sub(/^- Review\/Ship: /, ""); review = $0; next }
    cycle != "" && /^- Risk: / { sub(/^- Risk: /, ""); risk = $0; next }
    cycle != "" && /^- 결과: / { sub(/^- 결과: /, ""); result = $0; next }
    cycle != "" && /^- 이번에 한 일: / { sub(/^- 이번에 한 일: /, ""); work = $0; next }
    cycle != "" && /^- 결론: / { sub(/^- 결론: /, ""); conclusion = $0; next }
    cycle != "" && /^- 검증: / { sub(/^- 검증: /, ""); verification = $0; next }
    cycle != "" && /^- 리뷰\/배포: / { sub(/^- 리뷰\/배포: /, ""); review = $0; next }
    cycle != "" && /^- 리스크: / { sub(/^- 리스크: /, ""); risk = $0; next }
    END { flush() }
  ' "$log" | while IFS="$(printf '\034')" read -r cycle result work conclusion verification review risk; do
    [[ "$cycle" =~ ^[0-9]+$ ]] || continue
    result="${result:-legacy}"
    work="${work:-${conclusion:-기존 Markdown brief에서 복원한 cycle입니다.}}"
    conclusion="${conclusion:-$work}"
    verification="${verification:-기존 Markdown brief에서 복원했습니다.}"
    review="${review:-기존 Markdown brief에서 복원했습니다.}"
    if is_empty_risk "$risk"; then
      if ! jq -nc \
        --argjson cycle "$cycle" \
        --arg result "$result" \
        --arg work "$work" \
        --arg conclusion "$conclusion" \
        --arg verification "$verification" \
        --arg review "$review" \
        --arg run_id "$run_id" \
        --arg repo "$repo" \
        --arg repo_type "$repo_type" \
        --arg branch "$branch" \
        --arg head_sha "$head_sha" \
        '{
          schema_version:1,
          cycle:$cycle,
          result:$result,
          actions:[{kind:"legacy_markdown", summary_ko:$work}],
          conclusion:{summary_ko:$conclusion},
          changes:[],
          verification:[{kind:"legacy_markdown", status:"recorded", summary_ko:$verification}],
          review_ship:{status:"recorded", summary_ko:$review},
          next_candidates:[],
          risks:[],
          run_id:$run_id,
          recorded_at:"legacy_markdown_backfill",
          repo:{name:$repo, type:$repo_type, branch:$branch, head:$head_sha}
        }'; then
        exit 1
      fi
    else
      if ! jq -nc \
        --argjson cycle "$cycle" \
        --arg result "$result" \
        --arg work "$work" \
        --arg conclusion "$conclusion" \
        --arg verification "$verification" \
        --arg review "$review" \
        --arg risk "$risk" \
        --arg run_id "$run_id" \
        --arg repo "$repo" \
        --arg repo_type "$repo_type" \
        --arg branch "$branch" \
        --arg head_sha "$head_sha" \
        '{
          schema_version:1,
          cycle:$cycle,
          result:$result,
          actions:[{kind:"legacy_markdown", summary_ko:$work}],
          conclusion:{summary_ko:$conclusion},
          changes:[],
          verification:[{kind:"legacy_markdown", status:"recorded", summary_ko:$verification}],
          review_ship:{status:"recorded", summary_ko:$review},
          next_candidates:[],
          risks:[{summary_ko:$risk}],
          run_id:$run_id,
          recorded_at:"legacy_markdown_backfill",
          repo:{name:$repo, type:$repo_type, branch:$branch, head:$head_sha}
        }'; then
        exit 1
      fi
    fi
  done > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if [[ -s "$tmp" ]]; then
    mv "$tmp" "$jsonl" || {
      rm -f "$tmp"
      return 1
    }
  else
    rm -f "$tmp"
  fi
}

is_empty_risk() {
  local risk normalized
  risk="${1:-}"
  normalized="$(printf '%s' "$risk" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:].。]*$//')"
  case "$normalized" in
    ""|"없음"|"none"|"no risk"|"n/a"|"na") return 0 ;;
    *) return 1 ;;
  esac
}

render_cycle_markdown() {
  local payload_file="$1"
  jq -r '
    def result_label:
      (.result // "" | tostring) as $r |
      ($r | ascii_downcase | gsub("[ _-]"; "")) as $n |
      if $n == "allclear" then "ALL CLEAR"
      elif $n == "shipped" then "배포 완료 (shipped)"
      elif $n == "blocked" then "차단됨 (blocked)"
      elif $n == "docfixneeded" then "문서 수정 필요 (doc_fix_needed)"
      else $r end;
    def summaries($items):
      [($items // [])[]? | (.summary_ko // .summary // .command // empty) | tostring | select(. != "")];
    def joined($items):
      (summaries($items)) as $xs |
      if ($xs | length) == 0 then "기록 없음"
      elif ($xs | length) == 1 then $xs[0]
      else "\n" + ($xs | map("  - " + .) | join("\n")) end;
    def field($label; $value):
      if ($value | startswith("\n")) then "- \($label):\($value)"
      else "- \($label): \($value)" end;
    def candidate_line:
      "- " + ((.id // "후보") | tostring) +
      (if (.summary_ko // "") != "" then ": " + (.summary_ko | tostring) else "" end) +
      (if (.status // "") != "" then " (" + (.status | tostring) + ")" else "" end) +
      (if (.unblock_ko // "") != "" then " 시작 조건: " + (.unblock_ko | tostring) else "" end);
    def risk_line:
      ((.summary_ko // .summary // "기록 없음") | tostring) +
      (if (.issue_url // "") != "" then " (이슈: " + (.issue_url | tostring) + ")" else "" end) +
      (if (.issue_error // "") != "" then " (이슈 생성 실패: " + (.issue_error | tostring) + ")" else "" end) +
      (if (.next_action_ko // "") != "" then " 다음 조치: " + (.next_action_ko | tostring) else "" end);
    [
      "사이클 \(.cycle) 브리핑",
      "",
      "- 결과: \(result_label)",
      field("이번에 한 일"; joined(.actions)),
      "- 결론: \(.conclusion.summary_ko // "기록 없음")" + (if (.conclusion.reason_ko // "") != "" then " " + (.conclusion.reason_ko | tostring) else "" end),
      (if ((.next_candidates // []) | length) > 0 then "- 다음 검토 후보:\n" + ((.next_candidates // []) | map("  " + candidate_line) | join("\n")) else empty end),
      field("검증"; joined(.verification)),
      "- 리뷰/배포: \(.review_ship.summary_ko // .review_ship.status // "기록 없음")",
      (if ((.risks // []) | length) > 0 then "- 리스크:\n" + ((.risks // []) | map("  - " + risk_line) | join("\n")) else "- 리스크: 없음" end)
    ] | join("\n")
  ' "$payload_file"
}

finish_cycle_json_file() {
  local input_file="$1" output_mode="${2:-json}"
  local context run_id log state_dir jsonl cycle now branch head_sha repo repo_type record_file rendered issue_url issue_err issue_msg risk_count title summary
  require_jq || return 1
  context="$(brief_context)" || return 1
  run_id="$(printf '%s\n' "$context" | sed -n '1p')"
  log="$(printf '%s\n' "$context" | sed -n '2p')"
  state_dir="$(ensure_state_dir)"
  jsonl="$(brief_jsonl_file "$state_dir")"
  touch "$jsonl" || return 1
  backfill_jsonl_from_markdown_if_needed "$log" "$jsonl" "$run_id" || return 1

  if ! jq -e '
    def nonempty_string: type == "string" and test("\\S");
    def item_summary: ((.summary_ko // .summary // .command // "") | nonempty_string);
    type == "object" and
    .schema_version == 1 and
    ((.cycle | type) == "number") and (.cycle >= 1) and (.cycle == (.cycle | floor)) and
    (.result | nonempty_string) and
    (.actions | type == "array" and length > 0) and
    all(.actions[]; item_summary) and
    (.conclusion | type == "object") and
    (.conclusion.summary_ko | nonempty_string) and
    (.verification | type == "array" and length > 0) and
    all(.verification[]; item_summary) and
    (.review_ship | type == "object") and
    ((.review_ship.summary_ko // .review_ship.status // "") | nonempty_string) and
    (.risks | type == "array") and
    all(.risks[]; ((.summary_ko // .summary // "") | nonempty_string)) and
    (.next_candidates // [] | type == "array")
  ' "$input_file" >/dev/null; then
    echo "Invalid dev-cycle brief JSON. Required: schema_version=1, integer cycle, result, non-empty actions[].summary_ko, conclusion.summary_ko, non-empty verification[].summary_ko, review_ship summary/status, risks[].summary_ko when risks are present." >&2
    return 1
  fi

  cycle="$(jq -r '.cycle' "$input_file")" || return 1
  validate_cycle_append "$cycle" "$log" || return 1
  validate_jsonl_append "$cycle" "$jsonl" || return 1

  now="$(iso_now)"
  branch="$(git branch --show-current 2>/dev/null || true)"
  head_sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  repo="$(repo_name)"
  repo_type="$(repo_type)"
  record_file="$(mktemp)" || return 1
  jq \
    --arg run_id "$run_id" \
    --arg recorded_at "$now" \
    --arg repo "$repo" \
    --arg repo_type "$repo_type" \
    --arg branch "$branch" \
    --arg head_sha "$head_sha" \
    '. + {
      run_id:$run_id,
      recorded_at:$recorded_at,
      repo:{name:$repo, type:$repo_type, branch:$branch, head:$head_sha}
    } |
    .changes = (.changes // []) |
    .next_candidates = (.next_candidates // []) |
    .risks = ([.risks[]? | select(((.summary_ko // .summary // "") | tostring | length) > 0)])' \
    "$input_file" > "$record_file" || {
      rm -f "$record_file"
      return 1
    }

  risk_count="$(jq '[.risks[]? | select((.summary_ko // .summary // "") != "")] | length' "$record_file")" || {
    rm -f "$record_file"
    return 1
  }
  if (( risk_count > 0 )); then
    rendered="$(render_cycle_markdown "$record_file")" || {
      rm -f "$record_file"
      return 1
    }
    summary="$(jq -r '
      (.risks[0].summary_ko // .risks[0].summary // "dev-cycle risk")
      | tostring
      | split("\n")[0]
      | if length > 90 then .[0:90] else . end
    ' "$record_file")" || {
      rm -f "$record_file"
      return 1
    }
    title="[dev-cycle risk] $summary"
    issue_err="$(mktemp)" || {
      rm -f "$record_file"
      return 1
    }
    if issue_url="$(gh issue create --title "$title" --body "$rendered" 2>"$issue_err")"; then
      rm -f "$issue_err"
      jq --arg issue_url "$issue_url" '
        .risks = (.risks | map(. + {issue_url:$issue_url})) |
        .review_ship.summary_ko = ((.review_ship.summary_ko // .review_ship.status // "기록 없음") + "; 리스크 이슈 생성: " + $issue_url)
      ' "$record_file" > "$record_file.tmp" && mv "$record_file.tmp" "$record_file" || {
        rm -f "$record_file" "$record_file.tmp"
        return 1
      }
    else
      issue_msg="$(sed -n '1p' "$issue_err" 2>/dev/null || true)"
      rm -f "$issue_err"
      jq --arg issue_error "$issue_msg" '
        .risks = (.risks | map(. + {issue_error:$issue_error})) |
        .review_ship.summary_ko = ((.review_ship.summary_ko // .review_ship.status // "기록 없음") + "; 리스크 이슈 생성 실패")
      ' "$record_file" > "$record_file.tmp" && mv "$record_file.tmp" "$record_file" || {
        rm -f "$record_file" "$record_file.tmp"
        return 1
      }
      echo "리스크 이슈 생성 실패; 이슈 링크 없이 브리핑을 기록했습니다." >&2
    fi
  fi

  rendered="$(render_cycle_markdown "$record_file")" || {
    rm -f "$record_file"
    return 1
  }
  jq -c . "$record_file" >> "$jsonl" || {
    rm -f "$record_file"
    return 1
  }
  printf '%s\n\n' "$rendered" >> "$log" || {
    rm -f "$record_file"
    return 1
  }

  if [[ "$output_mode" == "markdown" ]]; then
    printf '%s\n\n' "$rendered" || {
      rm -f "$record_file"
      return 1
    }
  else
    jq -n \
      --slurpfile record "$record_file" \
      --arg rendered_markdown "$rendered" \
      '{ok:true, cycle:$record[0].cycle, result:$record[0].result, rendered_markdown:$rendered_markdown}' || {
        rm -f "$record_file"
        return 1
      }
  fi
  rm -f "$record_file"
}

finish_cycle_json() {
  local input_file status
  input_file="$(mktemp)" || return 1
  cat > "$input_file" || {
    rm -f "$input_file"
    return 1
  }
  if finish_cycle_json_file "$input_file" json; then
    status=0
  else
    status=$?
  fi
  rm -f "$input_file"
  return "$status"
}

finish_cycle() {
  local cycle result work verification review_ship risk next_action payload_file status
  cycle="${DEV_CYCLE_CYCLE:?set DEV_CYCLE_CYCLE}"
  result="${DEV_CYCLE_RESULT:?set DEV_CYCLE_RESULT}"
  work="${DEV_CYCLE_WORK:?set DEV_CYCLE_WORK}"
  verification="${DEV_CYCLE_VERIFICATION:?set DEV_CYCLE_VERIFICATION}"
  review_ship="${DEV_CYCLE_REVIEW_SHIP:?set DEV_CYCLE_REVIEW_SHIP}"
  risk="${DEV_CYCLE_RISK:-없음}"
  next_action="${DEV_CYCLE_NEXT_ACTION:-기록된 리스크를 다음 cycle에서 triage합니다.}"

  if [[ ! "$cycle" =~ ^[0-9]+$ ]]; then
    echo "DEV_CYCLE_CYCLE must be numeric for JSON brief handling" >&2
    return 1
  fi

  payload_file="$(mktemp)" || return 1
  if is_empty_risk "$risk"; then
    jq -n \
      --argjson cycle "$cycle" \
      --arg result "$result" \
      --arg work "$work" \
      --arg verification "$verification" \
      --arg review_ship "$review_ship" \
      '{
        schema_version:1,
        cycle:$cycle,
        result:$result,
        actions:[{kind:"legacy", summary_ko:$work}],
        conclusion:{summary_ko:$work},
        changes:[],
        verification:[{kind:"legacy", status:"recorded", summary_ko:$verification}],
        review_ship:{status:"recorded", summary_ko:$review_ship},
        next_candidates:[],
        risks:[]
      }' > "$payload_file" || {
        rm -f "$payload_file"
        return 1
      }
  else
    jq -n \
      --argjson cycle "$cycle" \
      --arg result "$result" \
      --arg work "$work" \
      --arg verification "$verification" \
      --arg review_ship "$review_ship" \
      --arg risk "$risk" \
      --arg next_action "$next_action" \
      '{
        schema_version:1,
        cycle:$cycle,
        result:$result,
        actions:[{kind:"legacy", summary_ko:$work}],
        conclusion:{summary_ko:$work},
        changes:[],
        verification:[{kind:"legacy", status:"recorded", summary_ko:$verification}],
        review_ship:{status:"recorded", summary_ko:$review_ship},
        next_candidates:[],
        risks:[{summary_ko:$risk, next_action_ko:$next_action}]
      }' > "$payload_file" || {
        rm -f "$payload_file"
        return 1
      }
  fi

  if finish_cycle_json_file "$payload_file" markdown; then
    status=0
  else
    status=$?
  fi
  rm -f "$payload_file"
  return "$status"
}

summary_json() {
  local context run_id log state_dir jsonl start_epoch_file start_epoch now elapsed elapsed_text repo
  require_jq || return 1
  context="$(brief_context)" || return 1
  run_id="$(printf '%s\n' "$context" | sed -n '1p')"
  log="$(printf '%s\n' "$context" | sed -n '2p')"
  state_dir="$(ensure_state_dir)"
  jsonl="$(brief_jsonl_file "$state_dir")"
  if [[ ! -f "$jsonl" ]]; then
    : > "$jsonl" || return 1
  fi
  backfill_jsonl_from_markdown_if_needed "$log" "$jsonl" "$run_id" || return 1
  validate_jsonl_state "$jsonl" || return 1
  start_epoch_file="$(brief_start_epoch_file "$state_dir")"
  elapsed=0
  if [[ -f "$start_epoch_file" ]]; then
    start_epoch="$(sed -n '1p' "$start_epoch_file")"
    if [[ "$start_epoch" =~ ^[0-9]+$ ]]; then
      now="$(date -u +%s)"
      elapsed=$((now - start_epoch))
    fi
  fi
  elapsed_text="$(format_duration "$elapsed")"
  repo="$(repo_name)"
  jq -n \
    --slurpfile cycles "$jsonl" \
    --arg run_id "$run_id" \
    --arg repo "$repo" \
    --arg log "$log" \
    --argjson elapsed_seconds "$elapsed" \
    --arg elapsed_text "$elapsed_text" '
    def result_label($r):
      ($r // "" | tostring) as $v |
      ($v | ascii_downcase | gsub("[ _-]"; "")) as $n |
      if $n == "allclear" then "ALL CLEAR"
      elif $n == "shipped" then "배포 완료 (shipped)"
      elif $n == "blocked" then "차단됨 (blocked)"
      elif $n == "docfixneeded" then "문서 수정 필요 (doc_fix_needed)"
      else $v end;
    def headline($c):
      $c.conclusion.summary_ko // ([$c.actions[]?.summary_ko][0]) // "기록 없음";
    def item_text:
      (.summary_ko // .summary // .command // empty) | tostring | select(. != "");
    def risk_text:
      ((.summary_ko // .summary // "기록 없음") | tostring) +
      (if (.issue_url // "") != "" then " (이슈: " + (.issue_url | tostring) + ")" else "" end) +
      (if (.issue_error // "") != "" then " (이슈 생성 실패: " + (.issue_error | tostring) + ")" else "" end) +
      (if (.next_action_ko // "") != "" then " 다음 조치: " + (.next_action_ko | tostring) else "" end);
    def candidate_text:
      ((.id // "후보") | tostring) + ": " +
      ((.summary_ko // "설명 없음") | tostring) +
      (if (.status // "") != "" then " (" + (.status | tostring) + ")" else "" end) +
      (if (.unblock_ko // "") != "" then " 시작 조건: " + (.unblock_ko | tostring) else "" end);
    def block($label; $xs):
      if ($xs | length) == 0 then "- \($label): 없음"
      elif ($xs | length) == 1 then "- \($label): \($xs[0])"
      else "- \($label):\n" + ($xs | map("  - " + .) | join("\n")) end;
    ($cycles | length) as $count |
    ($cycles[-1] // {}) as $last |
    ($last.next_candidates // []) as $candidates |
    ([
      "최종 브리핑",
      "",
      "- 결과: 총 \($count)개 사이클, 마지막 결과 \(result_label($last.result // "none"))",
      block("작업"; if $count == 0 then [] else [$cycles[] | "사이클 \(.cycle): \(headline(.))"] end),
      block("검증"; [$cycles[] as $c | ($c.verification // [])[]? | item_text as $v | "사이클 \($c.cycle): \($v)"]),
      block("리뷰/배포"; if $count == 0 then [] else [$cycles[] | "사이클 \(.cycle): \(.review_ship.summary_ko // .review_ship.status // "기록 없음")"] end),
      (if ($candidates | length) > 0 then block("다음 검토 후보"; [$candidates[] | candidate_text]) else empty end),
      block("리스크"; [$cycles[] as $c | ($c.risks // [])[]? | risk_text as $r | "사이클 \($c.cycle): \($r)"]),
      "- 걸린 시간: \($elapsed_text)"
    ] | join("\n")) as $rendered |
    {
      schema_version:1,
      run_id:$run_id,
      repo:$repo,
      log:$log,
      elapsed:{seconds:$elapsed_seconds, text:$elapsed_text},
      cycles:($cycles | map({cycle, result, headline_ko:headline(.)})),
      open_risks:[$cycles[]?.risks[]?],
      next_candidates:$candidates,
      rendered_markdown:$rendered
    }'
}

summary() {
  local context log state_dir start_epoch_file start_epoch now elapsed
  context="$(brief_context)"
  log="$(printf '%s\n' "$context" | sed -n '2p')"
  sed -n '1,120p' "$log"
  state_dir="$(ensure_state_dir)"
  start_epoch_file="$(brief_start_epoch_file "$state_dir")"
  if [[ -f "$start_epoch_file" ]]; then
    start_epoch="$(sed -n '1p' "$start_epoch_file")"
    if [[ "$start_epoch" =~ ^[0-9]+$ ]]; then
      now="$(date -u +%s)"
      elapsed=$((now - start_epoch))
      printf -- '- Elapsed: %s\n' "$(format_duration "$elapsed")"
    fi
  fi
}

usage() {
  cat <<'EOF'
usage: dev-cycle-helper.sh <command>

commands:
  direct-push-list
  repo-name
  repo-type
  default-branch
  review-base
  sync
  init-brief
  validate-brief <run-id> <brief-log>
  finish-cycle
  finish-cycle-json
  summary
  summary-json
EOF
}

cmd="${1:-}"
case "$cmd" in
  direct-push-list) direct_push_repos ;;
  repo-name) repo_name ;;
  repo-type) repo_type ;;
  default-branch) default_branch ;;
  review-base) review_base ;;
  sync) sync_repo ;;
  init-brief) init_brief ;;
  validate-brief) shift; validate_brief "$@" ;;
  finish-cycle) finish_cycle ;;
  finish-cycle-json) finish_cycle_json ;;
  summary) summary ;;
  summary-json) summary_json ;;
  help|-h|--help|"") usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
