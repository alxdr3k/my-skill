#!/usr/bin/env bash
# deploy.sh — Deploy commands/scripts to AI agent locations
#
# Usage:
#   ./deploy.sh user                  # user-level (symlinks, auto-update)
#   ./deploy.sh project <path>        # project-level (copies + git commit)
#   ./deploy.sh project <path> --dry  # dry run
#   ./deploy.sh all-projects          # ~/ws 전체 프로젝트에 배포 + git commit
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

_link() {   # _link src dst
  local src="$1" dst="$2"
  $DRY && { ok "[dry] symlink $dst → $src"; return; }
  mkdir -p "$(dirname "$dst")"
  ln -sf "$src" "$dst"
  ok "$(basename "$dst") → symlink"
}

_copy() {   # _copy src dst
  local src="$1" dst="$2"
  $DRY && { ok "[dry] copy $dst"; return; }
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  ok "$(basename "$dst") → copied"
}

# ── user-level (symlinks so edits propagate immediately) ─────────────────────

deploy_claude_user() {
  log "Claude  ~/.claude/commands/"
  for f in "$CMDS"/*.md; do
    _link "$f" "$HOME/.claude/commands/$(basename "$f")"
  done
}

deploy_opencode_user() {
  if [[ ! -d "$HOME/.opencode" ]]; then
    skip "opencode: ~/.opencode 없음 — skip"
    return
  fi
  log "opencode  ~/.opencode/command/"
  for f in "$CMDS"/*.md; do
    _link "$f" "$HOME/.opencode/command/$(basename "$f")"
  done
}

deploy_codex_user() {
  if [[ ! -d "$HOME/.codex" ]]; then
    skip "Codex: ~/.codex 없음 — skip"
    return
  fi
  log "Codex  ~/.codex/rules/default.rules"
  $DRY && { ok "[dry] copy default.rules"; return; }
  cp "$CODEX_RULES" "$HOME/.codex/rules/default.rules"
  ok "default.rules → copied"
}

# ── project-level (copies so commands are committed & available on mobile) ───

deploy_claude_project() {
  local proj="$1"
  log "Claude  $proj/.claude/commands/"
  for f in "$CMDS"/*.md; do
    _copy "$f" "$proj/.claude/commands/$(basename "$f")"
  done
  # scripts (referenced by codex-loop.md)
  log "Claude  $proj/.claude/scripts/"
  for f in "$SCRIPTS"/*; do
    _copy "$f" "$proj/.claude/scripts/$(basename "$f")"
    $DRY || chmod +x "$proj/.claude/scripts/$(basename "$f")"
  done
}

deploy_opencode_project() {
  local proj="$1"
  # opencode 프로젝트인지 확인
  if [[ ! -f "$proj/opencode.jsonc" && ! -d "$proj/.opencode" ]]; then
    skip "opencode: $proj 는 opencode 프로젝트 아님 — skip"
    return
  fi
  log "opencode  $proj/.opencode/command/"
  for f in "$CMDS"/*.md; do
    _copy "$f" "$proj/.opencode/command/$(basename "$f")"
  done
}

# ── git commit (touched paths only, skip if no changes) ─────────────────────

_git_commit() {
  local proj="$1"
  local prev_dir="$PWD"
  cd "$proj"

  git add ".claude/commands" ".claude/scripts" 2>/dev/null || true
  [[ -f "opencode.jsonc" || -d ".opencode" ]] && git add ".opencode/command" 2>/dev/null || true

  if git diff --cached --quiet; then
    skip "변경 없음 — commit skip"
    cd "$prev_dir"
    return 1
  fi

  git commit -m "chore: sync shared commands from alxdr3k/my-skill"
  ok "committed"
  cd "$prev_dir"
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
    if [[ -z "${2:-}" ]]; then
      err "Usage: $0 project <path> [--dry]"
      exit 1
    fi
    proj="${2%/}"   # trailing slash 제거
    if [[ ! -d "$proj" ]]; then
      err "디렉토리 없음: $proj"
      exit 1
    fi
    $DRY && echo "(dry run)"
    deploy_claude_project "$proj"
    deploy_opencode_project "$proj"
    if ! $DRY; then
      _git_commit "$proj"
    fi
    ;;
  all-projects)
    $DRY && echo "(dry run)"
    updated=0; unchanged=0
    # .claude/commands/ 와 .git/ 이 모두 있는 프로젝트를 depth 3까지 탐색
    while IFS= read -r proj; do
      [[ "$proj" == "$REPO" ]] && continue          # my-skill 자신 제외
      [[ ! -d "$proj/.git" ]] && continue           # git repo 아니면 skip
      [[ ! -d "$proj/.claude/commands" ]] && continue  # commands 없으면 skip
      echo ""
      log "프로젝트: $(basename "$proj")"
      deploy_claude_project "$proj"
      deploy_opencode_project "$proj"
      if ! $DRY; then
        if _git_commit "$proj"; then
          (( updated++ )) || true
        else
          (( unchanged++ )) || true
        fi
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
  $0 project <path>             프로젝트 레벨 배포 + git commit
  $0 project <path> --dry       dry run
  $0 all-projects               ~/ws 전체 프로젝트 배포 + git commit
  $0 all-projects --dry         dry run
  $0 list                       현재 커맨드 목록 및 배포 현황

지원 에이전트:
  Claude Code   ~/.claude/commands/  /  .claude/commands/
  opencode      ~/.opencode/command/ /  .opencode/command/
  Codex CLI     ~/.codex/rules/      (user only)
EOF
    ;;
esac
