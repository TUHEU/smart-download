#!/usr/bin/env bash
# =============================================================================
# update.sh — deploy / refresh the Smart Virtual Classroom download page
#
# What it does:
#   1. Checks that index.html and the QR image are present in this folder
#   2. Copies the site files into the web root (never deletes anything there,
#      so an APK already on the server is left alone)
#   3. Fixes permissions
#   4. (optional) Refreshes the DuckDNS record if DUCKDNS_TOKEN is set
#   5. Reloads nginx / apache if one is running
#   6. Checks that the site answers over HTTPS
#
# Usage:
#   ./update.sh                         # deploy to the default web root
#   WEB_ROOT=/var/www/mysite ./update.sh
#   DUCKDNS_TOKEN=xxxx-xxxx ./update.sh # also refresh the DuckDNS IP
#   ./update.sh --help
#
# Settings (override with environment variables):
#   WEB_ROOT        where the site is served from   (default: /var/www/html/smartclass)
#   APK_NAME        APK filename the page links to  (default: smart-virtual-classroom.apk)
#   SITE_URL        public address used for the check (default: https://smartclass1.duckdns.org)
#   DUCKDNS_DOMAIN  DuckDNS subdomain               (default: smartclass1)
#   DUCKDNS_TOKEN   DuckDNS token (leave empty to skip the DNS refresh)
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_ROOT="${WEB_ROOT:-/var/www/html/smartclass}"
APK_NAME="${APK_NAME:-smart-virtual-classroom.apk}"
SITE_URL="${SITE_URL:-https://smartclass1.duckdns.org}"
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:-smartclass1}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"

SITE_FILES=(index.html smartclass_qr_poster.png)

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# ---------- helpers ----------
if [[ -t 1 ]]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else G=; Y=; R=; B=; N=; fi
ok()   { echo "${G}✔${N} $*"; }
warn() { echo "${Y}!${N} $*"; }
fail() { echo "${R}✘${N} $*" >&2; exit 1; }
step() { echo; echo "${B}==> $*${N}"; }

# use sudo only when we need it
SUDO=""
if [[ $EUID -ne 0 ]]; then
  target="$WEB_ROOT"
  [[ -d "$target" ]] || target="$(dirname "$WEB_ROOT")"
  if [[ ! -w "$target" ]]; then
    command -v sudo >/dev/null 2>&1 || fail "Need write access to $WEB_ROOT and sudo is not available."
    SUDO="sudo"
  fi
fi

# ---------- 1. check source files ----------
step "Checking files in $SRC_DIR"
for f in "${SITE_FILES[@]}"; do
  [[ -f "$SRC_DIR/$f" ]] || fail "Missing $f next to update.sh"
  ok "$f"
done

if [[ -f "$SRC_DIR/$APK_NAME" ]]; then
  ok "$APK_NAME ($(du -h "$SRC_DIR/$APK_NAME" | cut -f1))"
  SITE_FILES+=("$APK_NAME")
elif [[ -f "$WEB_ROOT/$APK_NAME" ]]; then
  ok "$APK_NAME not in this folder, but already on the server — keeping it"
else
  warn "$APK_NAME not found here or in $WEB_ROOT — the Download button will fail until you add it"
fi

# ---------- 2. copy files ----------
step "Deploying to $WEB_ROOT"
$SUDO mkdir -p "$WEB_ROOT"
for f in "${SITE_FILES[@]}"; do
  $SUDO install -m 644 "$SRC_DIR/$f" "$WEB_ROOT/$f"
  ok "updated $f"
done

# ---------- 3. permissions ----------
step "Fixing permissions"
$SUDO chmod 755 "$WEB_ROOT"
if id www-data >/dev/null 2>&1; then
  $SUDO chown -R www-data:www-data "$WEB_ROOT" 2>/dev/null && ok "owner set to www-data" || warn "could not change owner (skipped)"
elif id nginx >/dev/null 2>&1; then
  $SUDO chown -R nginx:nginx "$WEB_ROOT" 2>/dev/null && ok "owner set to nginx" || warn "could not change owner (skipped)"
else
  warn "no www-data/nginx user found — owner left unchanged"
fi

# ---------- 4. DuckDNS (optional) ----------
step "DuckDNS"
if [[ -n "$DUCKDNS_TOKEN" ]]; then
  if command -v curl >/dev/null 2>&1; then
    resp="$(curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" || true)"
    [[ "$resp" == "OK" ]] && ok "${DUCKDNS_DOMAIN}.duckdns.org now points to this server" \
                          || warn "DuckDNS answered '${resp:-no response}' — check the domain and token"
  else
    warn "curl not installed — skipping DuckDNS refresh"
  fi
else
  echo "   DUCKDNS_TOKEN not set — skipping DNS refresh"
fi

# ---------- 5. reload web server ----------
step "Reloading web server"
SYSCTL_SUDO=""; [[ $EUID -ne 0 ]] && SYSCTL_SUDO="sudo"
reloaded=0
if command -v systemctl >/dev/null 2>&1; then
  for svc in nginx apache2 httpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      $SYSCTL_SUDO systemctl reload "$svc" && ok "reloaded $svc" && reloaded=1 && break
    fi
  done
fi
[[ $reloaded -eq 1 ]] || echo "   no running nginx/apache found — static files are served as-is, no reload needed"

# ---------- 6. verify ----------
step "Checking $SITE_URL"
if command -v curl >/dev/null 2>&1; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$SITE_URL" 2>/dev/null || true)"
  code="${code:-000}"
  if [[ "$code" == "200" ]]; then ok "site answers HTTP 200"; else warn "site answered HTTP $code (DNS or server config may still be catching up)"; fi
  apk_code="$(curl -s -o /dev/null -I -w '%{http_code}' --max-time 15 "$SITE_URL/$APK_NAME" 2>/dev/null || true)"
  apk_code="${apk_code:-000}"
  if [[ "$apk_code" == "200" ]]; then ok "APK is downloadable"; else warn "APK request answered HTTP $apk_code"; fi
else
  warn "curl not installed — skipping the check"
fi

echo
ok "${B}Done.${N}"
