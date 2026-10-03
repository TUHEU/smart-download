#!/usr/bin/env bash
# =============================================================================
# update.sh — pull the latest Smart Virtual Classroom page from the repository
#
# Put this script in the site folder (e.g. /var/www/smart-download) and run:
#
#   bash update.sh                  # pull the latest changes
#   bash update.sh --force          # discard local edits to tracked files, match the repo exactly
#   bash update.sh --help
#
# FIRST TIME on the server (folder is not a git repo yet):
#
#   cd /var/www/smart-download
#   REPO_URL=https://github.com/<you>/<repo>.git bash update.sh
#
# This links the folder to the repository and pulls it. Untracked files that
# are already there (like smart-virtual-classroom.apk) are left untouched.
#
# Settings (environment variables, all optional once the repo is linked):
#   REPO_URL   repository address (only needed for the first run)
#   BRANCH     branch to follow       (default: the repo's default branch)
#   WEB_ROOT   site folder            (default: the folder this script is in)
#   APK_NAME   APK the page links to  (default: smart-virtual-classroom.apk)
#   SITE_URL   address used for the final check (default: https://smartclass1.duckdns.org)
# =============================================================================
set -euo pipefail

main() {
  # NOTE: no "local" here — a local declaration would hide the values passed in
  # from the command line (REPO_URL=... bash update.sh)
  local FORCE=0 SRC_DIR
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  WEB_ROOT="${WEB_ROOT:-$SRC_DIR}"
  REPO_URL="${REPO_URL:-}"
  BRANCH="${BRANCH:-}"
  APK_NAME="${APK_NAME:-smart-virtual-classroom.apk}"
  SITE_URL="${SITE_URL:-https://smartclass1.duckdns.org}"

  for arg in "$@"; do
    case "$arg" in
      -f|--force) FORCE=1 ;;
      -h|--help)  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "Unknown option: $arg (try --help)" >&2; return 1 ;;
    esac
  done

  # ---------- helpers ----------
  local G="" Y="" R="" B="" N=""
  if [[ -t 1 ]]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; fi
  ok()   { echo "${G}✔${N} $*"; }
  warn() { echo "${Y}!${N} $*"; }
  fail() { echo "${R}✘${N} $*" >&2; exit 1; }
  step() { echo; echo "${B}==> $*${N}"; }
  # run git against the site folder; safe.directory avoids "dubious ownership"
  # errors when root runs git in a folder owned by www-data
  g() { git -c safe.directory="$WEB_ROOT" -C "$WEB_ROOT" "$@"; }

  command -v git >/dev/null 2>&1 || fail "git is not installed (apt install git)"
  [[ -d "$WEB_ROOT" ]] || fail "Folder $WEB_ROOT does not exist"
  [[ -w "$WEB_ROOT" ]] || fail "No write access to $WEB_ROOT — run as root or with sudo"

  local before after
  step "Updating $WEB_ROOT"

  if [[ ! -d "$WEB_ROOT/.git" ]]; then
    # ---------- first-time setup: link this folder to the repo ----------
    [[ -n "$REPO_URL" ]] || fail "This folder isn't linked to a repository yet.
   Run once with:  REPO_URL=https://github.com/<you>/<repo>.git bash update.sh"

    if [[ -z "$BRANCH" ]]; then
      BRANCH="$(git ls-remote --symref "$REPO_URL" HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}')" \
        || true
      [[ -n "$BRANCH" ]] || fail "Could not reach $REPO_URL (check the address, and the token/SSH key if the repo is private)"
    fi

    # keep a copy of the current page before the repo version replaces it
    if [[ -f "$WEB_ROOT/index.html" ]]; then
      local bak="$WEB_ROOT/index.html.bak.$(date +%Y%m%d%H%M%S)"
      cp "$WEB_ROOT/index.html" "$bak" && ok "backed up current index.html → $(basename "$bak")"
    fi

    g init -q
    g remote add origin "$REPO_URL"
    g fetch -q origin "$BRANCH" || fail "git fetch failed"
    g checkout -q -f -B "$BRANCH" "origin/$BRANCH"
    g branch -q --set-upstream-to="origin/$BRANCH" "$BRANCH" || true
    ok "linked to $REPO_URL (branch $BRANCH)"
    ok "now at $(g log -1 --format='%h %s')"
  else
    # ---------- normal update ----------
    [[ -n "$BRANCH" ]] || BRANCH="$(g rev-parse --abbrev-ref HEAD)"
    before="$(g rev-parse HEAD 2>/dev/null || echo none)"

    g fetch -q origin "$BRANCH" || fail "git fetch failed — check the network and repo access"

    if [[ $FORCE -eq 1 ]]; then
      g reset -q --hard "origin/$BRANCH"
      ok "reset to origin/$BRANCH (local edits to tracked files discarded)"
    else
      if ! g merge -q --ff-only "origin/$BRANCH" 2>/dev/null; then
        warn "Could not fast-forward — this folder has local changes or has diverged from the repo:"
        g status --short | sed 's/^/     /'
        fail "Re-run with --force to discard those changes and match the repo."
      fi
    fi

    after="$(g rev-parse HEAD)"
    if [[ "$before" == "$after" ]]; then
      ok "already up to date ($(g log -1 --format='%h %s'))"
    else
      ok "updated ${before:0:7} → ${after:0:7}"
      echo
      if [[ "$before" == "none" ]]; then g log --oneline -5 | sed 's/^/     /'
      else g log --oneline "$before..$after" | sed 's/^/     /'; fi
      echo
      g diff --stat "$before" "$after" 2>/dev/null | sed 's/^/     /' || true
    fi
  fi

  # ---------- check page assets ----------
  step "Checking files"
  local f
  for f in index.html; do
    [[ -f "$WEB_ROOT/$f" ]] && ok "$f" || warn "$f is missing from the repository"
  done
  if [[ -f "$WEB_ROOT/$APK_NAME" ]]; then
    ok "$APK_NAME ($(du -h "$WEB_ROOT/$APK_NAME" | cut -f1))"
  else
    warn "$APK_NAME not found — the Download button will fail until you upload it"
  fi

  # ---------- permissions (leave .git alone so git keeps working for this user) ----------
  step "Fixing permissions"
  chmod -R a+rX "$WEB_ROOT" 2>/dev/null || warn "could not adjust permissions"
  local webuser=""
  if id www-data >/dev/null 2>&1; then webuser="www-data"
  elif id nginx >/dev/null 2>&1; then webuser="nginx"; fi
  if [[ -n "$webuser" ]]; then
    if find "$WEB_ROOT" -path "$WEB_ROOT/.git" -prune -o -exec chown "$webuser:$webuser" {} + 2>/dev/null; then
      ok "files owned by $webuser"
    else
      warn "could not change owner (run as root to do that)"
    fi
  fi

  # ---------- verify ----------
  step "Checking $SITE_URL"
  if command -v curl >/dev/null 2>&1; then
    local code apk_code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$SITE_URL" 2>/dev/null || true)"; code="${code:-000}"
    [[ "$code" == "200" ]] && ok "site answers HTTP 200" || warn "site answered HTTP $code"
    apk_code="$(curl -s -o /dev/null -I -w '%{http_code}' --max-time 15 "$SITE_URL/$APK_NAME" 2>/dev/null || true)"; apk_code="${apk_code:-000}"
    [[ "$apk_code" == "200" ]] && ok "APK is downloadable" || warn "APK request answered HTTP $apk_code"
  else
    warn "curl not installed — skipping the check"
  fi

  echo; ok "${B}Done.${N}"
}

# everything is wrapped in main() so git can safely replace this very file
# while it runs (bash would otherwise read a half-changed script)
main "$@"
exit $?
