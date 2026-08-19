#!/usr/bin/env bash
#
# Verify that the deep-link association files are actually reachable and
# well-formed on the live site.
#
# This exists because two of the failure modes here are silent. GitHub Pages
# runs Jekyll by default, and Jekyll drops any directory starting with a dot -
# so /.well-known/ 404s even though the files are committed (the repo carries
# a .nojekyll file to stop that). And an extensionless file gets served as
# application/octet-stream, which Apple's documentation says must be
# application/json. Neither shows up until a link silently opens the browser.
#
# Usage: scripts/verify-applinks.sh [domain]   (default: nutovia.app)

set -uo pipefail

DOMAIN="${1:-nutovia.app}"
IOS_APPID_SUFFIX="app.nutovia.mobile"
ANDROID_PACKAGE="app.nutovia.mobile"

failures=0
warnings=0

fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
warn() { printf '  WARN  %s\n' "$1"; warnings=$((warnings + 1)); }
ok()   { printf '  ok    %s\n' "$1"; }

# Fetches a URL into $body and sets $code, $redirects, $ctype.
fetch() {
  body=$(mktemp)
  local meta
  meta=$(curl -sS -o "$body" -w '%{http_code} %{num_redirects} %{content_type}' "$1" 2>/dev/null)
  code=$(printf '%s' "$meta" | cut -d' ' -f1)
  redirects=$(printf '%s' "$meta" | cut -d' ' -f2)
  ctype=$(printf '%s' "$meta" | cut -d' ' -f3-)
}

echo "Checking https://$DOMAIN"
echo

# --- iOS: apple-app-site-association ----------------------------------------
echo "apple-app-site-association"
fetch "https://$DOMAIN/.well-known/apple-app-site-association"

if [ "$code" != "200" ]; then
  fail "HTTP $code (expected 200). If it is 404, the .nojekyll file is missing or Pages has not rebuilt yet."
else
  ok "HTTP 200"

  # Apple refuses to follow redirects when fetching this file.
  if [ "$redirects" != "0" ]; then
    fail "$redirects redirect(s) - Apple does not follow redirects for this file"
  else
    ok "no redirects"
  fi

  case "$ctype" in
    application/json*) ok "content-type: $ctype" ;;
    *) warn "content-type: $ctype (Apple documents application/json; GitHub Pages cannot set this, see README)" ;;
  esac

  if grep -q '__APPLE_TEAM_ID__' "$body"; then
    fail "still contains the __APPLE_TEAM_ID__ placeholder"
  elif python3 -c "
import json, sys
d = json.load(open('$body'))
ids = [a for x in d['applinks']['details'] for a in x['appIDs']]
assert any(a.endswith('.$IOS_APPID_SUFFIX') for a in ids), ids
assert all(len(a.split('.', 1)[0]) == 10 for a in ids), ids
print('  ok    appIDs: ' + ', '.join(ids))
" 2>/dev/null; then
    :
  else
    fail "not valid JSON, or appIDs are not <10-char TeamID>.$IOS_APPID_SUFFIX"
  fi
fi
rm -f "$body"
echo

# --- iOS: Apple's CDN copy ---------------------------------------------------
# Devices fetch through this CDN, not from the origin. A stale or missing entry
# here means the phone still sees the old file however right the origin looks.
echo "Apple CDN copy"
fetch "https://app-site-association.cdn-apple.com/a/v1/$DOMAIN"
if [ "$code" = "200" ] && python3 -c "
import json, sys
d = json.load(open('$body'))
assert d.get('applinks', {}).get('details'), d
" 2>/dev/null; then
  ok "Apple's CDN has an applinks entry for $DOMAIN"
else
  warn "Apple's CDN returned HTTP $code with no usable applinks entry - it can take a day to pick up a new file"
fi
rm -f "$body"
echo

# --- Android: assetlinks.json ------------------------------------------------
echo "assetlinks.json"
fetch "https://$DOMAIN/.well-known/assetlinks.json"

if [ "$code" != "200" ]; then
  fail "HTTP $code (expected 200)"
else
  ok "HTTP 200"

  if [ "$redirects" != "0" ]; then
    fail "$redirects redirect(s) - Android's verifier rejects redirects"
  else
    ok "no redirects"
  fi

  case "$ctype" in
    application/json*) ok "content-type: $ctype" ;;
    *) fail "content-type: $ctype (must be application/json)" ;;
  esac

  if grep -q '__PLAY_SHA256__' "$body"; then
    fail "still contains the __PLAY_SHA256__ placeholder"
  elif python3 -c "
import json, re, sys
d = json.load(open('$body'))
t = d[0]['target']
assert t['package_name'] == '$ANDROID_PACKAGE', t
fps = t['sha256_cert_fingerprints']
assert fps, 'no fingerprints'
for f in fps:
    assert re.fullmatch(r'([0-9A-F]{2}:){31}[0-9A-F]{2}', f), f
print('  ok    %d fingerprint(s), package %s' % (len(fps), t['package_name']))
" 2>/dev/null; then
    :
  else
    fail "not valid JSON, wrong package, or a fingerprint is not 32 colon-separated uppercase hex bytes"
  fi
fi
rm -f "$body"
echo

# --- Android: Google's own verifier -----------------------------------------
# This is the same service the device uses, so it is the answer that counts.
echo "Google Digital Asset Links API"
api="https://digitalassetlinks.googleapis.com/v1/statements:list"
api="$api?source.web.site=https://$DOMAIN"
api="$api&relation=delegate_permission/common.handle_all_urls"
fetch "$api"
if [ "$code" = "200" ] && python3 -c "
import json
d = json.load(open('$body'))
assert not d.get('debugString', '').strip().startswith('Error'), d.get('debugString')
pkgs = [s['target']['androidApp']['packageName'] for s in d.get('statements', []) if 'androidApp' in s.get('target', {})]
assert '$ANDROID_PACKAGE' in pkgs, pkgs
" 2>/dev/null; then
  ok "Google can verify $ANDROID_PACKAGE from $DOMAIN"
else
  warn "Google could not verify the statement yet (HTTP $code) - it caches, so retry in a few minutes"
fi
rm -f "$body"
echo

# --- Summary -----------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s), $warnings warning(s)."
  exit 1
fi
echo "All checks passed ($warnings warning(s))."
