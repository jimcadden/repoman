#!/usr/bin/env bash
# Regression test for scripts/vendor-engine.sh — the RepoMan v0.1.0 engine
# vendor + provenance stamp. Part of the RepoMan release (epic
# rossoctl/automation#72).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$SCRIPT_DIR/../scripts/vendor-engine.sh"
# Keep scratch trees outside the workspace so a botched git-init cannot stage
# or commit into the RepoMan working tree (git -C walks parents when .git is
# missing).
TMP=$(mktemp -d /tmp/repoman-vendor-test-XXXXXX); trap 'rm -rf "$TMP"' EXIT
fail=0

MANIFEST="automation-health-dashboard core dep-bump-fixer dep-bump-scanner \
extract-broken-links fork github-api link-health-fixer link-health-scanner \
org parse-diff-map pr-review-fixer pr-review-impact pr-review-lib \
pr-review-scanner program-lib repo-sync repoman-check repoman-index \
repoman-requirements repoman-run repoman-setup weekly-report"
EXTRA_FILES="link-check.py"

populate_scripts() {
  local dest="$1" include_py="${2:-yes}" include_org="${3:-yes}"
  mkdir -p "$dest/scripts"
  # shellcheck disable=SC2086
  for f in $MANIFEST; do
    if [ "$include_org" != "yes" ] && [ "$f" = "org" ]; then
      continue
    fi
    echo "#!/usr/bin/env bash" > "$dest/scripts/$f.sh"
  done
  if [ "$include_py" = "yes" ]; then
    # shellcheck disable=SC2086
    for f in $EXTRA_FILES; do
      echo "#!/usr/bin/env python3" > "$dest/scripts/$f"
    done
  fi
}

# Happy-path source must be a real git repo (vendor stamps HEAD). Prefer a
# fixture tree we just committed under /tmp; if git init is blocked (some
# sandboxes deny writing .git/config), fall back to an existing automation
# checkout that already has a valid HEAD.
SRC="$TMP/auto"
mkdir -p "$SRC"
populate_scripts "$SRC" yes yes
if git -C "$SRC" -c init.templateDir= init -q 2>/dev/null; then
  git -C "$SRC" -c user.email=t@t -c user.name=t add -A >/dev/null
  git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm "vendor-test fixture" >/dev/null
elif [ -f /tmp/automation-work/scripts/link-check.py ] && git -C /tmp/automation-work rev-parse HEAD >/dev/null 2>&1; then
  SRC=/tmp/automation-work
  echo "NOTE: using /tmp/automation-work as vendor source (git init blocked in this environment)"
else
  echo "FAIL: git init blocked and no fallback automation checkout available"; exit 1
fi

DEST="$TMP/dest"

# --- Happy path: all 23 .sh + link-check.py copied ---
if ! bash "$VENDOR" --source "$SRC" --dest "$DEST" >/dev/null 2>&1; then
  echo "FAIL: happy-path vendor returned non-zero"; fail=1
else
  echo "PASS: happy-path vendor returned zero"
fi
n=$(find "$DEST" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" = "23" ]; then echo "PASS: 23 scripts copied"; else echo "FAIL: copied $n .sh, expected 23"; fail=1; fi
if [ -f "$DEST/link-check.py" ]; then
  echo "PASS: link-check.py copied"
else
  echo "FAIL: link-check.py missing from dest"; fail=1
fi

# --- Provenance stamp ---
want=$(git -C "$SRC" rev-parse HEAD)
got=$(jq -r '.source_sha' "$DEST/_vendor.json" 2>/dev/null)
if [ "$got" = "$want" ]; then echo "PASS: stamp sha == source HEAD"; else echo "FAIL: stamp sha $got != source $want"; fail=1; fi
if jq -e '.files | length == 24' "$DEST/_vendor.json" >/dev/null 2>&1; then
  echo "PASS: stamp lists 24 files"; else echo "FAIL: stamp file list wrong"; fail=1
fi
if jq -e '.files | index("link-check.py")' "$DEST/_vendor.json" >/dev/null 2>&1; then
  echo "PASS: stamp includes link-check.py"; else echo "FAIL: stamp missing link-check.py"; fail=1
fi
if jq -e '.source_repo == "rossoctl/automation"' "$DEST/_vendor.json" >/dev/null 2>&1; then
  echo "PASS: stamp names source repo"; else echo "FAIL: stamp source_repo wrong"; fail=1
fi

# --- Idempotency ---
bash "$VENDOR" --source "$SRC" --dest "$DEST" >/dev/null 2>&1
got2=$(jq -r '.source_sha' "$DEST/_vendor.json" 2>/dev/null)
if [ "$got2" = "$want" ]; then echo "PASS: idempotent stamp sha"; else echo "FAIL: idempotency $got2 != $want"; fail=1; fi

# --- Missing .sh source fails before any copy (no git needed: pre-validate) ---
BADDEST="$TMP/baddest"
BAD="$TMP/bad"
populate_scripts "$BAD" yes no
if ! bash "$VENDOR" --source "$BAD" --dest "$BADDEST" >/dev/null 2>&1; then
  echo "PASS: missing .sh source fails loud"
else
  echo "FAIL: missing .sh source did not fail"; fail=1
fi
copied=$(find "$BADDEST" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "${copied:-0}" = "0" ]; then
  echo "PASS: no half-vendored dir (dest empty on failure)"
else
  echo "FAIL: $copied files copied before the abort (half-vendored)"; fail=1
fi

# --- Missing link-check.py also fails before any copy ---
BADDEST2="$TMP/baddest2"
BAD2="$TMP/bad2"
populate_scripts "$BAD2" no yes
if ! bash "$VENDOR" --source "$BAD2" --dest "$BADDEST2" >/dev/null 2>&1; then
  echo "PASS: missing link-check.py fails loud"
else
  echo "FAIL: missing link-check.py did not fail"; fail=1
fi
copied2=$(find "$BADDEST2" -maxdepth 1 \( -name '*.sh' -o -name 'link-check.py' \) 2>/dev/null | wc -l | tr -d ' ')
if [ "${copied2:-0}" = "0" ]; then
  echo "PASS: no half-vendored dir when py missing"
else
  echo "FAIL: $copied2 files copied before py abort"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
