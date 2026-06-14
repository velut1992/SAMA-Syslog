#!/bin/bash
# lib.sh — shared logging + result-accumulation helpers for the Supra installer
# test harness. Sourced by verify.sh and the runners. Pure bash, no deps.

# Result accumulator. Each check appends one line "STATUS|NAME|DETAIL" to $RESULTS_FILE.
: "${RESULTS_FILE:=/tmp/supra-test-results.$$}"
: "${REPORT_TITLE:=Supra Installer Test}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'

log()  { echo -e "${c_cyn}==>${c_rst} $*"; }
warn() { echo -e "${c_yel}WARN:${c_rst} $*"; }
err()  { echo -e "${c_red}ERROR:${c_rst} $*" >&2; }

results_init() { : > "$RESULTS_FILE"; }

# record STATUS NAME DETAIL   (STATUS = PASS|FAIL|SKIP)
record() {
  local status="$1" name="$2" detail="${3:-}"
  printf '%s|%s|%s\n' "$status" "$name" "$detail" >> "$RESULTS_FILE"
  case "$status" in
    PASS) echo -e "  ${c_grn}[PASS]${c_rst} $name${detail:+ — $detail}";;
    FAIL) echo -e "  ${c_red}[FAIL]${c_rst} $name${detail:+ — $detail}";;
    SKIP) echo -e "  ${c_yel}[SKIP]${c_rst} $name${detail:+ — $detail}";;
  esac
}

# check NAME  <command...>   -> PASS if command exits 0, else FAIL
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then record PASS "$name"; else record FAIL "$name" "check failed: $*"; fi
}

# check_msg NAME DETAIL  <command...>
check_msg() {
  local name="$1" detail="$2"; shift 2
  if "$@" >/dev/null 2>&1; then record PASS "$name" "$detail"; else record FAIL "$name" "$detail"; fi
}

counts() { # echoes "PASS FAIL SKIP TOTAL"
  # grep -c prints 0 but exits 1 on zero matches; capture stdout, ignore exit.
  local p f s
  p=$(grep -c '^PASS|' "$RESULTS_FILE" 2>/dev/null); p=${p:-0}
  f=$(grep -c '^FAIL|' "$RESULTS_FILE" 2>/dev/null); f=${f:-0}
  s=$(grep -c '^SKIP|' "$RESULTS_FILE" 2>/dev/null); s=${s:-0}
  echo "$p $f $s $((p+f+s))"
}

# write_report REPORT_MD ENV_LABEL INSTALL_LOG
# Emits a markdown report from $RESULTS_FILE; returns nonzero if any FAIL.
write_report() {
  local out="$1" envlabel="$2" installlog="${3:-}"
  read -r P F S T <<<"$(counts)"
  local verdict="PASS"; [ "$F" -gt 0 ] && verdict="FAIL"
  {
    echo "# ${REPORT_TITLE}"
    echo
    echo "- **Target:** ${envlabel}"
    echo "- **Date:** $(date -u '+%Y-%m-%d %H:%M:%SZ')"
    echo "- **Result:** **${verdict}**  (PASS ${P} / FAIL ${F} / SKIP ${S}, total ${T})"
    echo
    echo "## Checks"
    echo
    echo "| Status | Check | Detail |"
    echo "|--------|-------|--------|"
    while IFS='|' read -r st name detail; do
      local icon="✅"; [ "$st" = FAIL ] && icon="❌"; [ "$st" = SKIP ] && icon="⏭️"
      echo "| ${icon} ${st} | ${name} | ${detail} |"
    done < "$RESULTS_FILE"
    if [ -n "$installlog" ] && [ -f "$installlog" ]; then
      echo
      echo "## Installer output (tail)"
      echo
      echo '```'
      tail -n 40 "$installlog"
      echo '```'
    fi
  } > "$out"
  log "Report written: $out"
  [ "$F" -eq 0 ]
}
