#!/usr/bin/env bash
# deploy.sh — Deploy commands/scripts to AI agent locations
#
# Usage:
#   ./deploy.sh user                  # user-level (symlinks, auto-update)
#   ./deploy.sh project <path>        # project-level (worktree + git commit + push)
#   ./deploy.sh project <path> --dry  # dry run
#   ./deploy.sh all-projects          # ~/ws 전체 프로젝트에 배포
#   ./deploy.sh all-projects --dry    # dry run

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CMDS="$REPO/commands"
SCRIPTS="$REPO/scripts"
CODEX_RULES="$REPO/codex/rules/default.rules"

GRN='\033[0;32m'; BLU='\033[0;34m'; YLW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${BLU}→${NC} $*"; }
ok()   { echo -e "${GRN}✓${NC} $*"; }
skip() { echo -e "${YLW}–${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*"; }

DRY=false
[[ "${*}" == *"--dry"* ]] && DRY=true

_link() {
  local src="$1" dst="$2"
  $DRY && { ok "[dry] symlink $(basename "$dst")"; return; }
  mkdir -p "$(dirname "$dst")"
  ln -sf "$src" "$dst"
  ok "$(basename "$dst") → symlink"
}

_copy() {
  local src="$1" dst="$2"
  $DRY && { ok "[dry] copy $(basename "$dst")"; return; }
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  ok "$(basename "$dst") → copied"
}

# ── user-level (symlinks so edits propagate immediately) ─────────────────────

deploy_claude_user() {
  log "Claude  ~/.claude/commands/"
  for f in "$CMDS"/*.md; do _link "$f" "$HOME/.claude/commands/$(basename "$f")"; done
}

deploy_opencode_user() {
  if [[ ! -d "$HOME/.opencode" ]]; then skip "opencode: ~/.opencode 없음 — skip"; return; fi
  log "opencode  ~/.opencode/command/"
  for f in "$CMDS"/*.md; do _link "$f" "$HOME/.opencode/command/$(basename "$f")"; done
}

deploy_codex_user() {
  if [[ ! -d "$HOME/.codex" ]]; then skip "Codex: ~/.codex 없음 — skip"; return; fi
  log "Codex  ~/.codex/rules/default.rules"
  $DRY && { ok "[dry] copy default.rules"; return; }
  cp "$CODEX_RULES" "$HOME/.codex/rules/default.rules"
  ok "default.rules → copied"
}

# ── copy files to a destination path ─────────────────────────────────────────

_copy_claude_to() {
  local dest="$1"
  log "Claude  $dest/.claude/"
  for f in "$CMDS"/*.md; do _copy "$f" "$dest/.claude/commands/$(basename "$f")"; done
  for f in "$SCRIPTS"/*; do
    _copy "$f" "$dest/.claude/scripts/$(basename "$f")"
    $DRY || chmod +x "$dest/.claude/scripts/$(basename "$f")"
  done
}

_copy_opencode_to() {
  local dest="$1" proj="$2"
  if [[ ! -f "$proj/opencode.jsonc" && ! -d "$proj/.opencode" ]]; then
    skip "opencode: $(basename "$proj") 는 opencode 프로젝트 아님 — skip"
    return
  fi
  log "opencode  $dest/.opencode/command/"
  for f in "$CMDS"/*.md; do _copy "$f" "$dest/.opencode/command/$(basename "$f")"; done
}

# ── base branch detection ─────────────────────────────────────────────────────

_base_branch() {
  local proj="$1"
  local repo_name
  repo_name="$(basename "$proj")"
  if grep -qxF "$repo_name" "$REPO/direct-push-repos.txt" 2>/dev/null; then
    echo "main"
  elif git -C "$proj" show-ref --verify --quiet refs/heads/dev; then
    echo "dev"
  else
    echo "main"
  fi
}

# ── git: worktree → commit → push → squash merge base → push ─────────────────

_git_deploy() {
  local proj="$1"
  local repo_name base
  repo_name="$(basename "$proj")"
  base="$(_base_branch "$proj")"

  local branch="chore/sync-commands"
  local merge_branch="temp-sync-merge"
  local wt_branch="/tmp/my-skill-${repo_name}-branch"

  # 잔여 worktree/branch 정리
  git -C "$proj" worktree remove "$wt_branch" --force 2>/dev/null || true
  rm -rf "$wt_branch"
  git -C "$proj" branch -D "$branch" "$merge_branch" 2>/dev/null || true

  if $DRY; then
    _copy_claude_to "$proj"
    _copy_opencode_to "$proj" "$proj"
    ok "[dry] would commit + push + squash merge → $base"
    return 0
  fi

  # origin/base 최신화 후 detached HEAD로 worktree 생성 (로컬 base 브랜치 불필요)
  git -C "$proj" fetch origin "$base" -q
  git -C "$proj" worktree add --detach "$wt_branch" "origin/$base" -q
  git -C "$wt_branch" checkout -b "$branch" -q

  # 파일 복사 (worktree로)
  _copy_claude_to "$wt_branch"
  _copy_opencode_to "$wt_branch" "$proj"

  # 프로젝트에 잘못 배포된 direct-push-repos.txt 제거
  rm -f "$wt_branch/.claude/direct-push-repos.txt"
  git -C "$wt_branch" rm --cached --force ".claude/direct-push-repos.txt" -q 2>/dev/null || true

  # stage
  git -C "$wt_branch" add ".claude" 2>/dev/null || true
  git -C "$wt_branch" add ".opencode" 2>/dev/null || true

  if git -C "$wt_branch" diff --cached --quiet; then
    skip "변경 없음 — skip"
    git -C "$proj" worktree remove "$wt_branch" --force; rm -rf "$wt_branch"
    return 1
  fi

  git -C "$wt_branch" commit -m "chore: sync shared commands from alxdr3k/my-skill" -q
  ok "committed on $branch"
  git -C "$wt_branch" push --set-upstream origin "$branch" -q
  ok "pushed $branch"

  # 같은 worktree에서 origin/base 기반 임시 브랜치로 squash merge 후 push
  # → 로컬 base 브랜치 체크아웃 불필요, 메인 워크트리 무간섭
  git -C "$wt_branch" checkout -b "$merge_branch" "origin/$base" -q
  git -C "$wt_branch" merge --squash "$branch" -q
  git -C "$wt_branch" commit -m "chore: sync shared commands from alxdr3k/my-skill" -q
  git -C "$wt_branch" push origin "$merge_branch:$base" -q
  ok "merged → $base, pushed"

  # 로컬 프로젝트 동기화 (Claude Code는 로컬 파일 읽음)
  # untracked 커맨드 파일 정리 후 pull → remote 상태와 일치시킴
  git -C "$proj" clean -f ".claude/commands/" ".claude/scripts/" 2>/dev/null || true
  git -C "$proj" pull --ff-only -q 2>/dev/null || true
  # pull 후에도 없는 파일은 로컬 복사 (e.g. 로컬이 feature 브랜치인 경우)
  _copy_claude_to "$proj"
  _copy_opencode_to "$proj" "$proj"
  rm -f "$proj/.claude/direct-push-repos.txt"
  ok "local synced"

  # worktree 및 브랜치 정리
  git -C "$proj" worktree remove "$wt_branch" --force
  rm -rf "$wt_branch"
  git -C "$proj" branch -D "$branch" "$merge_branch" 2>/dev/null || true
  git -C "$proj" push origin --delete "$branch" -q 2>/dev/null || true

  return 0
}

# ── entrypoint ────────────────────────────────────────────────────────────────

case "${1:-help}" in
  user)
    $DRY && echo "(dry run)"
    deploy_claude_user
    deploy_opencode_user
    deploy_codex_user
    echo ""
    echo "완료. 이후 commands/ 수정 시 symlink로 자동 반영됩니다."
    ;;
  project)
    if [[ -z "${2:-}" ]]; then err "Usage: $0 project <path> [--dry]"; exit 1; fi
    proj="${2%/}"
    [[ ! -d "$proj" ]] && { err "디렉토리 없음: $proj"; exit 1; }
    $DRY && echo "(dry run)"
    _git_deploy "$proj"
    ;;
  all-projects)
    $DRY && echo "(dry run)"
    updated=0; unchanged=0
    while IFS= read -r proj; do
      [[ "$proj" == "$REPO" ]] && continue
      [[ ! -d "$proj/.git" ]] && continue
      [[ ! -d "$proj/.claude/commands" ]] && continue
      echo ""
      log "프로젝트: $(basename "$proj")"
      if _git_deploy "$proj"; then
        (( updated++ )) || true
      else
        (( unchanged++ )) || true
      fi
    done < <(find "$HOME/ws" -maxdepth 3 -name ".claude" -type d -exec dirname {} \; | sort -u)
    echo ""
    $DRY || echo "완료: ${updated}개 업데이트, ${unchanged}개 변경 없음"
    ;;
  list)
    echo "=== commands/ ==="
    ls "$CMDS"/*.md | xargs -I{} basename {}
    echo ""
    echo "=== scripts/ ==="
    ls "$SCRIPTS"/ 2>/dev/null || echo "(없음)"
    echo ""
    echo "=== 배포 현황 ==="
    echo "Claude user:    ~/.claude/commands/"
    ls "$HOME/.claude/commands/" 2>/dev/null | sed 's/^/  /'
    echo "opencode user:  ~/.opencode/command/"
    ls "$HOME/.opencode/command/" 2>/dev/null | sed 's/^/  /' || echo "  (없음)"
    ;;
  help|*)
    cat <<EOF
사용법:
  $0 user                       유저 레벨 배포 (symlink, 수정 즉시 반영)
  $0 project <path>             프로젝트 레벨 배포 (worktree + commit + push)
  $0 project <path> --dry       dry run
  $0 all-projects               ~/ws 전체 프로젝트 배포
  $0 all-projects --dry         dry run
  $0 list                       현재 커맨드 목록 및 배포 현황

지원 에이전트:
  Claude Code   ~/.claude/commands/  /  .claude/commands/
  opencode      ~/.opencode/command/ /  .opencode/command/
  Codex CLI     ~/.codex/rules/      (user only)
EOF
    ;;
esac
