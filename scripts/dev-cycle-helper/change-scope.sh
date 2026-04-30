# shellcheck shell=bash

line_count() {
  local file="$1"
  if [[ -s "$file" ]]; then
    wc -l < "$file" | tr -d ' '
  else
    echo 0
  fi
}

git_ref_exists() {
  git rev-parse --verify --quiet "$1" >/dev/null
}

review_range_ref() {
  local type="$1" base="$2"

  if [[ "$type" == "direct-push" ]] && git_ref_exists "refs/remotes/origin/main"; then
    echo "origin/main"
    return
  fi

  if git_ref_exists "$base"; then
    echo "$base"
  elif git_ref_exists "refs/remotes/origin/$base"; then
    echo "origin/$base"
  else
    echo ""
  fi
}

is_docs_path() {
  local path="$1"
  case "$path" in
    *.md|*.mdx|*.markdown|*.rst|*.adoc|*.txt) return 0 ;;
    docs/*|doc/*) return 0 ;;
    AGENTS.md|CLAUDE.md|README|README.*|CHANGELOG|CHANGELOG.*) return 0 ;;
    commands/*.md|codex/skills/*/SKILL.md|codex/rules/*.rules) return 0 ;;
    .claude/commands/*.md|.codex/skills/*/SKILL.md|.codex/skill-overrides/*.md) return 0 ;;
    *) return 1 ;;
  esac
}

is_contract_docs_path() {
  local path="$1"
  case "$path" in
    AGENTS.md|CLAUDE.md) return 0 ;;
    commands/*.md|codex/skills/*/SKILL.md|codex/rules/*.rules) return 0 ;;
    .claude/commands/*.md|.codex/skills/*/SKILL.md|.codex/skill-overrides/*.md) return 0 ;;
    docs/specs/*|docs/*SPEC*|docs/*spec*|docs/*SCHEMA*|docs/*schema*) return 0 ;;
    docs/*STATUS*|docs/*status*|docs/*ROADMAP*|docs/*roadmap*) return 0 ;;
    docs/*IMPLEMENTATION_PLAN*|docs/*DECISION*|docs/*QUESTIONS*) return 0 ;;
    *) return 1 ;;
  esac
}

classify_change_scope() {
  local files_file="$1" count all_docs contract_surface path
  count="$(line_count "$files_file")"
  if (( count == 0 )); then
    echo "none none false false"
    return
  fi

  all_docs=true
  contract_surface=false
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! is_docs_path "$path"; then
      all_docs=false
    fi
    if is_contract_docs_path "$path"; then
      contract_surface=true
    fi
  done < "$files_file"

  if [[ "$all_docs" == "true" && "$contract_surface" == "true" ]]; then
    echo "docs_only_contract docs_contract true false"
  elif [[ "$all_docs" == "true" ]]; then
    echo "docs_only_low_risk docs_only false false"
  else
    echo "code_or_runtime full true true"
  fi
}

change_scope() {
  local type base range_ref tmp_dir committed staged unstaged untracked changed
  local committed_count staged_count unstaged_count untracked_count changed_count
  local scope_kind profile contract_surface full_ci_required
  local range_command
  require_jq || return 1

  type="$(repo_type)"
  base="$(review_base)"
  range_ref="$(review_range_ref "$type" "$base")"
  range_command=""
  tmp_dir="$(mktemp -d)" || return 1
  committed="$tmp_dir/committed"
  staged="$tmp_dir/staged"
  unstaged="$tmp_dir/unstaged"
  untracked="$tmp_dir/untracked"
  changed="$tmp_dir/changed"

  : > "$committed"
  if [[ -n "$range_ref" ]]; then
    if git diff --name-only "$range_ref...HEAD" > "$committed" 2>/dev/null; then
      range_command="git diff $range_ref...HEAD"
    elif git diff --name-only "$range_ref" HEAD > "$committed" 2>/dev/null; then
      range_command="git diff $range_ref HEAD"
    else
      : > "$committed"
    fi
  fi
  git diff --cached --name-only > "$staged"
  git diff --name-only > "$unstaged"
  git ls-files --others --exclude-standard > "$untracked"
  {
    cat "$committed"
    cat "$staged"
    cat "$unstaged"
    cat "$untracked"
  } | sed '/^$/d' | sort -u > "$changed"

  committed_count="$(line_count "$committed")"
  staged_count="$(line_count "$staged")"
  unstaged_count="$(line_count "$unstaged")"
  untracked_count="$(line_count "$untracked")"
  changed_count="$(line_count "$changed")"

  read -r scope_kind profile contract_surface full_ci_required < <(classify_change_scope "$changed")

  if jq -n \
    --arg repo "$(repo_name)" \
    --arg repo_type "$type" \
    --arg review_base "$base" \
    --arg range_ref "$range_ref" \
    --arg range_command "$range_command" \
    --rawfile committed "$committed" \
    --rawfile staged "$staged" \
    --rawfile unstaged "$unstaged" \
    --rawfile untracked "$untracked" \
    --rawfile changed "$changed" \
    --argjson committed_count "$committed_count" \
    --argjson staged_count "$staged_count" \
    --argjson unstaged_count "$unstaged_count" \
    --argjson untracked_count "$untracked_count" \
    --argjson changed_count "$changed_count" \
    --arg scope_kind "$scope_kind" \
    --arg profile "$profile" \
    --argjson contract_surface "$contract_surface" \
    --argjson full_ci_required "$full_ci_required" '
    def lines($s): $s | split("\n") | map(select(length > 0));
    def review_input($kind; $summary; $command; $files):
      {kind:$kind, summary:$summary, command:$command, files:$files};
    (lines($committed)) as $committed_files |
    (lines($staged)) as $staged_files |
    (lines($unstaged)) as $unstaged_files |
    (lines($untracked)) as $untracked_files |
    (lines($changed)) as $changed_files |
    {
      schema_version:1,
      kind:"dev_cycle_change_scope",
      repo:{name:$repo, type:$repo_type},
      review_base:$review_base,
      change_scope:{
        kind:$scope_kind,
        changed_files_count:$changed_count,
        contract_surface:$contract_surface,
        review_required:($changed_count > 0),
        changed_files:$changed_files
      },
      verification_profile:{
        profile:$profile,
        full_ci_required:$full_ci_required,
        checks:(
          if $profile == "none" then ["git status --short"]
          elif $profile == "docs_only" then ["git diff --check", "relevant markdown/document validation only"]
          elif $profile == "docs_contract" then ["git diff --check", "render/generated skill consistency when command or skill docs changed", "schema/example validation when contract docs changed"]
          else ["repo /verify", "repo full/pre-PR checks"] end
        ),
        skipped:(
          if $full_ci_required then []
          else ["unit/app CI unless repo guidance requires it for the touched docs"] end
        )
      },
      review_inputs:(
        []
        + (if $committed_count > 0 then [review_input("base_range"; "committed changes since review base"; $range_command; $committed_files)] else [] end)
        + (if $staged_count > 0 then [review_input("staged_diff"; "staged changes"; "git diff --cached"; $staged_files)] else [] end)
        + (if $unstaged_count > 0 then [review_input("unstaged_diff"; "unstaged changes"; "git diff"; $unstaged_files)] else [] end)
        + (if $untracked_count > 0 then [review_input("untracked_files"; "untracked files"; "git ls-files --others --exclude-standard"; $untracked_files)] else [] end)
      )
    }'; then
    rm -rf "$tmp_dir"
    return 0
  else
    local status=$?
    rm -rf "$tmp_dir"
    return "$status"
  fi
}
