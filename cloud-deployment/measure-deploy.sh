#!/bin/bash
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$SCRIPT_DIR/measurements/$RUN_ID"
SUMMARY="$OUT_DIR/summary.tsv"

mkdir -p "$OUT_DIR"
printf "phase\taction\tseconds\tstatus\tlog\n" > "$SUMMARY"

run_phase() {
  local phase="$1"
  local action="$2"
  local log="$OUT_DIR/phase-${phase}.log"
  local start end seconds status

  echo "==> Measuring phase $phase: $action"
  start="$(date +%s)"
  set +e
  "$SCRIPT_DIR/deploy.sh" --phase "$phase" > "$log" 2>&1
  status="$?"
  set -e
  end="$(date +%s)"
  seconds="$((end - start))"

  printf "%s\t%s\t%s\t%s\t%s\n" "$phase" "$action" "$seconds" "$status" "$log" >> "$SUMMARY"
  echo "==> Phase $phase finished in ${seconds}s with status $status"

  if [[ "$status" != "0" ]]; then
    echo "Phase $phase failed. Log: $log"
    exit "$status"
  fi
}

run_phase 1 "Bootstrap nodes"
run_phase 2 "Deploy K3S"
run_phase 3 "Prepare Ceph"
run_phase 4 "Install Kolla and configure"
run_phase 5 "Deploy OpenStack"
run_phase 6 "Init resources"
run_phase 7 "Deploy portal"

echo "==> Measurement summary: $SUMMARY"
