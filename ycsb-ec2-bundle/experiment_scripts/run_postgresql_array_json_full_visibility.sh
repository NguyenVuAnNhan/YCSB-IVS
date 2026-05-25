#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    cat <<'USAGE'
Usage:
  DB_PWD=... RUN_ID=full_view_run3 ./run_postgresql_array_json_full_visibility.sh [extra harness args]

This is the frozen full-visibility launcher for experiment_postgresql_array_json.sh.
Set parameters with environment variables; pass extra harness flags after them.

Common parameters:
  RUN_ID                         benchrun id; default: ${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}_full_visibility
  DB_NAME                        default: full_visibility
  UNCHANGE_DB_NAME               default: ${DB_NAME}_unchange
  BACKUP_DB_NAME                 default: ${DB_NAME}_backup
  DB_USERNAME                    default: ycsb
  DB_PWD or DB_PASSWORD          required
  RUN                            run counter; default: 1
  TYPE, DIST, SCALE, WORK        naming fields; defaults: full_visibility, zipfian, heavy, pure
  RECORDCOUNT                    default: 10000
  OPERATIONCOUNT                 default: 100000
  EXPERIMENT_EPOCHS              default: 10
  EXPERIMENT_RUNS_PER_EPOCH      default: 10
  EXTEND_OPERATIONCOUNT          default: OPERATIONCOUNT
  VACUUM_ENABLED                 default: 1
  COMPARISON_INTERVAL            default: 0

Phase parameters:
  EXTEND_REQUESTDISTRIBUTION     default: zipfian
  EXTEND_READREQUESTDISTRIBUTION default: uniform
  EXTEND_UPDATEREQUESTDISTRIBUTION default: uniform
  RUN_REQUESTDISTRIBUTION        default: uniform
  RUN_READREQUESTDISTRIBUTION    default: uniform
  RUN_UPDATEREQUESTDISTRIBUTION  default: uniform
  RUN_READPROPORTION             default: 1
  RUN_UPDATEPROPORTION           default: 0

Visibility parameters:
  SAMPLE_INTERVAL_SECONDS        default: 5
  RELATION_SIZE_SAMPLE_INTERVAL_SECONDS default: 30
  REQUIRE_FULL_VISIBILITY        default: 1
  SPIKE_TRIGGER_PREWARM_ENABLED  default: 0; this is an intervention, not visibility
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ -n "${DB_PASSWORD:-}" ] && [ -z "${DB_PWD:-}" ]; then
    export DB_PWD="$DB_PASSWORD"
fi
: "${DB_PWD:?Set DB_PWD or DB_PASSWORD before starting a full-visibility run.}"

export PGHOST="${PGHOST:-localhost}"
export DB_USERNAME="${DB_USERNAME:-ycsb}"
export PG_EXTENSION_USERNAME="${PG_EXTENSION_USERNAME:-$DB_USERNAME}"
export PG_EXTENSION_PWD="${PG_EXTENSION_PWD:-$DB_PWD}"

export TYPE="${TYPE:-full_visibility}"
export DIST="${DIST:-zipfian}"
export SCALE="${SCALE:-heavy}"
export WORK="${WORK:-pure}"
export RUN="${RUN:-1}"
export RUN_ID="${RUN_ID:-${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}_full_visibility}"

export DB_NAME="${DB_NAME:-full_visibility}"
export UNCHANGE_DB_NAME="${UNCHANGE_DB_NAME:-${DB_NAME}_unchange}"
export BACKUP_DB_NAME="${BACKUP_DB_NAME:-${DB_NAME}_backup}"
export DB_URL="${DB_URL:-jdbc:postgresql://localhost:5432/$DB_NAME}"
export UNCHANGE_DB_URL="${UNCHANGE_DB_URL:-jdbc:postgresql://localhost:5432/$UNCHANGE_DB_NAME}"
export BACKUP_URL="${BACKUP_URL:-jdbc:postgresql://localhost:5432/$BACKUP_DB_NAME}"

export RECORDCOUNT="${RECORDCOUNT:-10000}"
export OPERATIONCOUNT="${OPERATIONCOUNT:-100000}"
export EXPERIMENT_EPOCHS="${EXPERIMENT_EPOCHS:-10}"
export EXPERIMENT_RUNS_PER_EPOCH="${EXPERIMENT_RUNS_PER_EPOCH:-10}"
export EXTEND_OPERATIONCOUNT="${EXTEND_OPERATIONCOUNT:-$OPERATIONCOUNT}"
export VACUUM_ENABLED="${VACUUM_ENABLED:-1}"
export COMPARISON_INTERVAL="${COMPARISON_INTERVAL:-0}"

export EXTEND_EXTENDPROPORTION="${EXTEND_EXTENDPROPORTION:-1}"
export EXTEND_READPROPORTION="${EXTEND_READPROPORTION:-0}"
export EXTEND_UPDATEPROPORTION="${EXTEND_UPDATEPROPORTION:-0}"
export EXTEND_SCANPROPORTION="${EXTEND_SCANPROPORTION:-0}"
export EXTEND_INSERTPROPORTION="${EXTEND_INSERTPROPORTION:-0}"
export EXTEND_READMODIFYWRITEPROPORTION="${EXTEND_READMODIFYWRITEPROPORTION:-0}"
export EXTEND_REQUESTDISTRIBUTION="${EXTEND_REQUESTDISTRIBUTION:-zipfian}"
export EXTEND_READREQUESTDISTRIBUTION="${EXTEND_READREQUESTDISTRIBUTION:-uniform}"
export EXTEND_UPDATEREQUESTDISTRIBUTION="${EXTEND_UPDATEREQUESTDISTRIBUTION:-uniform}"

export RUN_EXTENDPROPORTION="${RUN_EXTENDPROPORTION:-0}"
export RUN_READPROPORTION="${RUN_READPROPORTION:-1}"
export RUN_UPDATEPROPORTION="${RUN_UPDATEPROPORTION:-0}"
export RUN_SCANPROPORTION="${RUN_SCANPROPORTION:-0}"
export RUN_INSERTPROPORTION="${RUN_INSERTPROPORTION:-0}"
export RUN_READMODIFYWRITEPROPORTION="${RUN_READMODIFYWRITEPROPORTION:-0}"
export RUN_REQUESTDISTRIBUTION="${RUN_REQUESTDISTRIBUTION:-uniform}"
export RUN_READREQUESTDISTRIBUTION="${RUN_READREQUESTDISTRIBUTION:-uniform}"
export RUN_UPDATEREQUESTDISTRIBUTION="${RUN_UPDATEREQUESTDISTRIBUTION:-uniform}"

WORKLOAD_TEMPLATE="${WORKLOAD_TEMPLATE:-$SCRIPT_DIR/../workloads/workloada-extend}"
WORKLOAD_CLEAN="${WORKLOAD_CLEAN:-$SCRIPT_DIR/${RUN_ID}_workloada-extend}"
cp "$WORKLOAD_TEMPLATE" "$WORKLOAD_CLEAN"

upsert_workload() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$WORKLOAD_CLEAN"; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$WORKLOAD_CLEAN"
    else
        printf '%s=%s\n' "$key" "$value" >> "$WORKLOAD_CLEAN"
    fi
}

sed -i '/^fieldlengthdistribution=/d;/^fieldlengthhistogram=/d' "$WORKLOAD_CLEAN"
upsert_workload recordcount "$RECORDCOUNT"
upsert_workload operationcount "$OPERATIONCOUNT"
upsert_workload requestdistribution "$RUN_REQUESTDISTRIBUTION"
upsert_workload readrequestdistribution "$RUN_READREQUESTDISTRIBUTION"
upsert_workload updaterequestdistribution "$RUN_UPDATEREQUESTDISTRIBUTION"
upsert_workload readproportion "$RUN_READPROPORTION"
upsert_workload updateproportion "$RUN_UPDATEPROPORTION"
upsert_workload scanproportion "$RUN_SCANPROPORTION"
upsert_workload insertproportion "$RUN_INSERTPROPORTION"
upsert_workload extendproportion "$RUN_EXTENDPROPORTION"
upsert_workload readmodifywriteproportion "$RUN_READMODIFYWRITEPROPORTION"
if [ -n "${FIELD_LENGTH_ORIGINAL:-}" ]; then
    upsert_workload fieldlength "$FIELD_LENGTH_ORIGINAL"
fi

export WORKLOAD_FILE="$WORKLOAD_CLEAN"
export BENCHRUN_OUTPUT_DIR="${BENCHRUN_OUTPUT_DIR:-$SCRIPT_DIR/benchruns}"
export BENCHRUN_FULL_VISIBILITY=1
export BENCHRUN_REQUIRE_FULL_VISIBILITY="${REQUIRE_FULL_VISIBILITY:-1}"
export BENCHRUN_INSPECT_WAL_RANGES=1
export BENCHRUN_ENABLE_OS_WATCHERS=1
export BENCHRUN_SKIP_CONTINUOUS_SAMPLING=0
export SPIKE_TRIGGER_TRACE_ENABLED=1
export SPIKE_TRIGGER_CHECKPOINT_LOGS_ENABLED=1
export SPIKE_TRIGGER_PAGE_IDENTITY_ENABLED=1
export SPIKE_TRIGGER_FREESPACE_ENABLED=1
export SPIKE_TRIGGER_PG_STAT_STATEMENTS_ENABLED=1
export SPIKE_TRIGGER_PG_STAT_STATEMENTS_RESET_PER_PHASE=1
export SPIKE_TRIGGER_WALINSPECT_ENABLED=1
export SPIKE_TRIGGER_WALINSPECT_PER_RECORD="${SPIKE_TRIGGER_WALINSPECT_PER_RECORD:-1}"
export SPIKE_TRIGGER_WALINSPECT_MAX_BYTES="${SPIKE_TRIGGER_WALINSPECT_MAX_BYTES:-0}"
export SPIKE_TRIGGER_PREWARM_ENABLED="${SPIKE_TRIGGER_PREWARM_ENABLED:-0}"

SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-5}"
RELATION_SIZE_SAMPLE_INTERVAL_SECONDS="${RELATION_SIZE_SAMPLE_INTERVAL_SECONDS:-30}"

HARNESS_ARGS=(
    --run-id "$RUN_ID" \
    --sample-interval-seconds "$SAMPLE_INTERVAL_SECONDS" \
    --relation-size-sample-interval-seconds "$RELATION_SIZE_SAMPLE_INTERVAL_SECONDS" \
    --full-visibility
)
if [ "$BENCHRUN_REQUIRE_FULL_VISIBILITY" = "1" ]; then
    HARNESS_ARGS+=(--require-full-visibility)
fi

exec ./experiment_postgresql_array_json.sh "${HARNESS_ARGS[@]}" "$@"
