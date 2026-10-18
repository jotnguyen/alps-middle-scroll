#!/usr/bin/env bash
# Hygiene gate for this public repo. Fails (exit 1) if content or a commit message
# holds something personal or secret: a private key or GitHub token, a long digit
# run (serials, phone numbers), a MAC address, an IPv4 address other than loopback,
# a Windows profile path (also in file names), a Firefox profile folder ID, a device
# instance ID, an email address other than a placeholder or GitHub noreply, an AI
# attribution trailer, or a HEAD commit made with a non-noreply identity.
#
#   bash scripts/hygiene.sh              # the tracked tree (CI)
#   bash scripts/hygiene.sh --cached     # staged content (.githooks/pre-commit)
#   bash scripts/hygiene.sh --msg FILE   # a commit message (.githooks/commit-msg)
#
# It skips itself, because it holds the patterns as literals.
set -euo pipefail

mode=tree
msg_file=
case "${1:-}" in
  --cached) mode=cached ;;
  --msg)
    mode=msg
    # Resolve before the cd below: git passes a path relative to the worktree.
    msg_file="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    ;;
esac
cd "$(dirname "$0")/.."
fail=0

# scan <grep flag> <ERE>: file:line hits in the tree, the index, or the message.
scan() {
  case "${mode}" in
    msg) grep -v '^#' "${msg_file}" | grep -n "$1" -E "$2" || true ;;
    cached) git grep --cached -n "$1" -E "$2" -- . ':!scripts/hygiene.sh' || true ;;
    *) git grep -n "$1" -E "$2" -- . ':!scripts/hygiene.sh' || true ;;
  esac
}

# report <label> <hits>
report() {
  [ -z "$2" ] && return 0
  echo "$1:"
  echo "$2"
  fail=1
}

report "SECRET (remove it)" "$(scan -I 'BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}')"
report "LONG NUMBER: serial or phone? (remove it)" "$(scan -I '(^|[^0-9A-Za-z])[0-9]{11,}([^0-9A-Za-z]|$)')"
report "MAC ADDRESS (remove it)" "$(scan -iI '(^|[^0-9a-f])([0-9a-f]{2}[:-]){5}[0-9a-f]{2}([^0-9a-f]|$)')"
# 10.0.0.126 is the AlpsAlpine Virtual HID driver version, not an address.
report "IP ADDRESS (only loopback; use <ip> otherwise)" \
  "$(scan -o '(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)' \
    | grep -vE ':[^0-9]?(127\.0\.0\.1|0\.0\.0\.0|10\.0\.0\.126)[^0-9]?$' || true)"
profile_path='[a-z]:[\\/]+users[\\/]+[a-z0-9._-]|(^|[^a-z0-9])/(mnt/)?c/users/[a-z0-9._-]|c--users-[a-z0-9]'
firefox_id='(^|[^a-z0-9])[a-z0-9]{8}\.(default(-release|-esr|-nightly)?|dev-edition-default)([^a-z0-9-]|$)'
report 'WINDOWS PROFILE PATH (use %USERPROFILE% or %APPDATA%)' "$(scan -i "${profile_path}")"
report 'FIREFOX PROFILE ID (use <id>.default-release)' "$(scan -i "${firefox_id}")"
report 'DEVICE INSTANCE ID (cut it after the hardware ID)' "$(scan -iI '(^|[^0-9a-z])[0-9]&[0-9a-f]{6,8}&[0-9]&[0-9a-f]{4}([^0-9a-z]|$)')"
# Every email address except placeholders and GitHub noreply ones.
report "EMAIL ADDRESS (use you@example.com)" \
  "$(scan -oiI '[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}' \
    | grep -viE '@(example\.(com|org|net)|users\.noreply\.github\.com)$' || true)"

# File and folder names can leak too (only in tree and cached mode).
if [ "${mode}" != msg ]; then
  if [ "${mode}" = cached ]; then names="$(git diff --cached --name-only --diff-filter=ACMR)"
  else names="$(git ls-files)"; fi
  report "PERSONAL DATA IN A FILE NAME" \
    "$(printf '%s\n' "${names}" | grep -iE "${profile_path}|${firefox_id}" || true)"
fi

attribution='^(Co-Authored-By: Claude|Claude-Session:)|Generated with \[?Claude Code|noreply@anthropic\.com'
if [ "${mode}" = msg ]; then
  grep -v '^#' "${msg_file}" | grep -qiE "${attribution}" \
    && report "ATTRIBUTION TRAILER in the commit message" "(remove the trailer)"
elif [ "${mode}" = tree ] && git log -1 --format=%B 2>/dev/null | grep -qiE "${attribution}"; then
  report "ATTRIBUTION TRAILER in the HEAD commit message" "(reword the commit)"
fi

# The HEAD commit must use a GitHub noreply identity (tree mode, once a commit exists).
if [ "${mode}" = tree ] && git rev-parse -q --verify HEAD >/dev/null; then
  for who in "$(git log -1 --format=%ae)" "$(git log -1 --format=%ce)"; do
    case "${who}" in
      *@users.noreply.github.com | noreply@github.com) ;;
      *) report "COMMIT IDENTITY is not a GitHub noreply address" "${who}" ;;
    esac
  done
fi

[ "${fail}" -eq 0 ] && echo "hygiene-ok"
exit "${fail}"
