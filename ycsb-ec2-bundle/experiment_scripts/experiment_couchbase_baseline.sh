#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$YCSB_HOME/bin:$PATH"

YCSB="../bin/ycsb.sh"

# Ensure required modules are staged for source-run
ensure_core_dependencies() {
    if [ ! -d "$YCSB_HOME/core/target/dependency" ] || [ ! -d "$YCSB_HOME/couchbase2/target/dependency" ]; then
        echo "[WARN] core/couchbase2 dependencies missing; building with -Psource-run..."
        mvn -Psource-run -pl site.ycsb:core,site.ycsb:couchbase2-binding -am package -DskipTests -Dcheckstyle.skip=true
    fi
}

# Couchbase connection settings
COUCHBASE_HOST="127.0.0.1"
COUCHBASE_BUCKET="ycsb"
COUCHBASE_USERNAME="ycsb"
COUCHBASE_PASSWORD="USyd2025"
# Note: for the couchbase binding, records are addressed by key in a bucket.
# There is no relational "table" concept.
COUCHBASE_BOOST="1"
INSERTION_RETRY_LIMIT="20"
INSERTION_RETRY_INTERVAL="2"
MAX_EXCEPTION_BLOCKS="3"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_couchbase_results.log"
OUTPUT_CSV="../analysis/couchbase_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/couchbase_output.csv"
OUTPUT_FILE="../analysis/Data/Baseline_data/couchbase_run1_spreadrun_heavy.csv"

# Extend phase experiment parameters
extendproportion_extend="0"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="1"
readmodifywriteproportion_extend="0"
requestdistribution_extend="uniform"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="1"
updateproportion_postextend="0"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="10000"
LAST_YCSB_EXIT_CODE=0
WORKLOAD_BACKUP_FILE=""

# Function to log and print messages
log() {
    echo "$1" | tee -a "$LOG_FILE"
}

restore_workload_file() {
    if [ -n "${WORKLOAD_BACKUP_FILE:-}" ] && [ -f "$WORKLOAD_BACKUP_FILE" ]; then
        cp "$WORKLOAD_BACKUP_FILE" "$WORKLOAD_FILE"
        rm -f "$WORKLOAD_BACKUP_FILE"
        log "Restored original workload file: $WORKLOAD_FILE"
    fi
}

backup_workload_file() {
    WORKLOAD_BACKUP_FILE=$(mktemp)
    cp "$WORKLOAD_FILE" "$WORKLOAD_BACKUP_FILE"
}

print_couchbase_debug_snapshot() {
    log "=== Couchbase debug snapshot ==="
    log "Host=$COUCHBASE_HOST Bucket=$COUCHBASE_BUCKET Username=$COUCHBASE_USERNAME Boost=$COUCHBASE_BOOST"
    log "YCSB retries: core_workload_insertion_retry_limit=$INSERTION_RETRY_LIMIT core_workload_insertion_retry_interval=$INSERTION_RETRY_INTERVAL"
    log "Exception capture: first $MAX_EXCEPTION_BLOCKS blocks per YCSB invocation"
    if command -v curl >/dev/null 2>&1; then
        local pools_http buckets_http
        pools_http=$(curl -s -o /dev/null -w "%{http_code}" "http://$COUCHBASE_HOST:8091/pools" || true)
        buckets_http=$(curl -s -u "$COUCHBASE_USERNAME:$COUCHBASE_PASSWORD" -o /dev/null -w "%{http_code}" "http://$COUCHBASE_HOST:8091/pools/default/buckets/$COUCHBASE_BUCKET" || true)
        log "HTTP probe /pools status=$pools_http"
        log "HTTP probe /pools/default/buckets/$COUCHBASE_BUCKET status=$buckets_http"
    else
        log "curl not found; skipping HTTP probes."
    fi
}

preflight_couchbase_or_die() {
    log "=== Couchbase preflight check ==="
    if ! command -v curl >/dev/null 2>&1; then
        log "[ERROR] curl is required for Couchbase preflight checks but was not found in PATH."
        exit 1
    fi

    local pools_http buckets_http
    pools_http=$(curl -s -o /dev/null -w "%{http_code}" "http://$COUCHBASE_HOST:8091/pools" || true)
    buckets_http=$(curl -s -u "$COUCHBASE_USERNAME:$COUCHBASE_PASSWORD" -o /dev/null -w "%{http_code}" "http://$COUCHBASE_HOST:8091/pools/default/buckets/$COUCHBASE_BUCKET" || true)

    log "Preflight /pools status=$pools_http"
    log "Preflight /pools/default/buckets/$COUCHBASE_BUCKET status=$buckets_http"

    if [ "$buckets_http" != "200" ]; then
        log "[ERROR] Couchbase preflight failed: bucket '$COUCHBASE_BUCKET' is not reachable/authenticated (HTTP $buckets_http)."
        log "[ERROR] Aborting before YCSB phases for correctness."
        exit 1
    fi

    if [ "$pools_http" != "200" ] && [ "$pools_http" != "401" ]; then
        log "[ERROR] Couchbase preflight failed: management endpoint /pools returned HTTP $pools_http (expected 200 or 401)."
        log "[ERROR] Aborting before YCSB phases for correctness."
        exit 1
    fi
}

append_limited_stderr() {
    local stderr_file="$1"
    local phase_label="$2"
    awk -v max_blocks="$MAX_EXCEPTION_BLOCKS" -v phase="$phase_label" '
        function is_exception_start(line) {
            return (line ~ /Exception:/ || line ~ /^Error inserting,/);
        }
        function is_stack_line(line) {
            return (line ~ /^[[:space:]]+at / || line ~ /^Caused by:/ || line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]+\.\.\. [0-9]+ more/);
        }
        BEGIN {
            exception_blocks = 0;
            mode = 0; # 0=normal, 1=emit stack, 2=suppress stack
            suppressed = 0;
        }
        {
            line = $0;
            if (is_exception_start(line)) {
                exception_blocks++;
                if (exception_blocks <= max_blocks) {
                    print line;
                    mode = 1;
                } else {
                    suppressed++;
                    mode = 2;
                }
                next;
            }

            if (mode == 1) {
                if (is_stack_line(line)) {
                    print line;
                    next;
                }
                mode = 0;
            } else if (mode == 2) {
                if (is_stack_line(line)) {
                    next;
                }
                mode = 0;
            }

            print line;
        }
        END {
            if (suppressed > 0) {
                printf "[debug][%s] Suppressed %d additional exception blocks (showing first %d).\n", phase, suppressed, max_blocks;
            }
        }
    ' "$stderr_file" >> "$LOG_FILE"
}

has_failed_operation_counts() {
    local output_file="$1"
    awk '
        match($0, /\[[A-Z-]+-FAILED: Count=([0-9]+)/, m) {
            if ((m[1] + 0) > 0) {
                found = 1;
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$output_file"
}

validate_ycsb_outcome_or_die() {
    local phase_label="$1"
    local rc="$2"
    local stderr_file="$3"

    if [ "$rc" -ne 0 ]; then
        log "[ERROR] YCSB $phase_label exited with status $rc. Aborting immediately."
        exit 1
    fi

    if grep -Eq 'Exception:|RequestCancelledException|Error inserting,' "$stderr_file"; then
        log "[ERROR] YCSB $phase_label emitted exceptions on stderr. Aborting immediately."
        exit 1
    fi

    if has_failed_operation_counts "$OUTPUT_CSV"; then
        log "[ERROR] YCSB $phase_label reported non-zero *-FAILED counts in $OUTPUT_CSV. Aborting immediately."
        exit 1
    fi
}

print_workload_debug_snapshot() {
    if [ -f "$WORKLOAD_FILE" ]; then
        local rc oc rp up ip ep reqd
        rc=$(awk -F= '/^recordcount=/{print $2}' "$WORKLOAD_FILE" | tail -1)
        oc=$(awk -F= '/^operationcount=/{print $2}' "$WORKLOAD_FILE" | tail -1)
        rp=$(awk -F= '/^readproportion=/{print $2}' "$WORKLOAD_FILE" | tail -1)
        up=$(awk -F= '/^updateproportion=/{print $2}' "$WORKLOAD_FILE" | tail -1)
        ip=$(awk -F= '/^insertproportion=/{print $2}' "$WORKLOAD_FILE" | tail -1)
        ep=$(awk -F= '/^extendproportion=/{print $2}' "$WORKLOAD_FILE" | tail -1)
        reqd=$(awk -F= '/^requestdistribution=/{print $2}' "$WORKLOAD_FILE" | tail -1)
        log "Workload snapshot: recordcount=$rc operationcount=$oc read=$rp update=$up insert=$ip extend=$ep requestdist=$reqd"
    else
        log "Workload file not found: $WORKLOAD_FILE"
    fi
}

# Couchbase binding does not expose PostgreSQL-equivalent metrics.
# Keep schema compatibility with baseline CSV by filling these as 0.
collect_couchbase_metrics() {
    blks_read=0
    blks_hit=0
    tup_returned=0
    tup_fetched=0
    tup_inserted=0
    tup_updated=0
    tup_deleted=0
    deadlocks=0
    temp_files=0
    temp_bytes=0
    checkpoints_timed=0
    checkpoints_req=0
    buffers_checkpoint=0
    buffers_clean=0
    buffers_backend=0
    buffers_alloc=0
    checkpoint_write_time=0
    checkpoint_sync_time=0
    wal_bytes=0
    wal_records=0
    wal_fpi=0
    wal_buffers_full=0
}

run_ycsb_load() {
    log "Running YCSB load with couchbase2 binding..."
    print_workload_debug_snapshot
    local stderr_tmp
    local rc
    stderr_tmp=$(mktemp)
    set +e
    "$YCSB" load couchbase2 -s -P "$WORKLOAD_FILE" \
        -p couchbase.host="$COUCHBASE_HOST" \
        -p couchbase.bucket="$COUCHBASE_BUCKET" \
        -p couchbase.password="$COUCHBASE_PASSWORD" \
        -p couchbase.boost="$COUCHBASE_BOOST" \
        -p core_workload_insertion_retry_limit="$INSERTION_RETRY_LIMIT" \
        -p core_workload_insertion_retry_interval="$INSERTION_RETRY_INTERVAL" > "$OUTPUT_CSV" 2>"$stderr_tmp"
    rc=$?
    set -e
    append_limited_stderr "$stderr_tmp" "load"
    LAST_YCSB_EXIT_CODE=$rc
    validate_ycsb_outcome_or_die "load" "$rc" "$stderr_tmp"
    rm -f "$stderr_tmp"
}

run_ycsb_run() {
    log "Running YCSB run with couchbase2 binding..."
    print_workload_debug_snapshot
    local stderr_tmp
    local rc
    stderr_tmp=$(mktemp)
    set +e
    "$YCSB" run couchbase2 -s -P "$WORKLOAD_FILE" \
        -p couchbase.host="$COUCHBASE_HOST" \
        -p couchbase.bucket="$COUCHBASE_BUCKET" \
        -p couchbase.password="$COUCHBASE_PASSWORD" \
        -p couchbase.boost="$COUCHBASE_BOOST" \
        -p core_workload_insertion_retry_limit="$INSERTION_RETRY_LIMIT" \
        -p core_workload_insertion_retry_interval="$INSERTION_RETRY_INTERVAL" > "$OUTPUT_CSV" 2>"$stderr_tmp"
    rc=$?
    set -e
    append_limited_stderr "$stderr_tmp" "run"
    LAST_YCSB_EXIT_CODE=$rc
    validate_ycsb_outcome_or_die "run" "$rc" "$stderr_tmp"
    rm -f "$stderr_tmp"
}

# Function to write results as a csv
write_result() {
    local first="$1"
    # Filter for inserts, reads, updates, scans, and extends
    # Also catch the overall output
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    if [ "$first" == "TRUE" ]; then
        local metric_columns
        local base_header
        metric_columns=$(awk '{print $2}' <<< "$filtered_output" | sed 's/,$//' | uniq | awk '{ORS=","; print}' | sed 's/,$//')
        base_header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes,checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time,wal_bytes,wal_records,wal_fpi,wal_buffers_full,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec)"
        # Create header
        if [ -n "$metric_columns" ]; then
            header="$base_header,$metric_columns"
        else
            header="$base_header"
            log "[WARN] No operation metric columns detected while creating CSV header."
        fi
        echo "$header" > "$OUTPUT_FILE"
    fi

    # Set default values for epoch and run if not set
    epoch=${epoch:-0}
    run=${run:-0}
    # Load phase counts as 0
    if [ "$phase" == "load" ]; then
        r=0
    else
        r=$((10 * (epoch - 1) + run))
    fi

    # Set default values for workload parameters
    recordcount=${recordcount:-""}
    readallfields=${readallfields:-""}
    requestdistribution=${requestdistribution:-""}
    readproportion=${readproportion:-""}
    updateproportion=${updateproportion:-""}
    scanproportion=${scanproportion:-""}
    insertproportion=${insertproportion:-""}
    extendproportion=${extendproportion:-""}

    # Extract runtime and throughput from overall output
    run_specific=()
    while IFS= read -r inner_line; do
        tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
        run_specific+=("$tmp")
    done <<< "$overall_output"
    runtime_ms=""
    throughput_ops=""
    if [ "${#run_specific[@]}" -gt 0 ]; then
        runtime_ms="${run_specific[0]}"
    else
        log "[WARN] Missing [OVERALL] runtime metric in $INPUT_FILE for phase=$phase epoch=$epoch run=$run."
    fi
    if [ "${#run_specific[@]}" -gt 1 ]; then
        throughput_ops="${run_specific[1]}"
    else
        log "[WARN] Missing [OVERALL] throughput metric in $INPUT_FILE for phase=$phase epoch=$epoch run=$run."
    fi

    # Iterate through each line
    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
    operation=""
    while IFS= read -r line; do
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')

        # Build CSV row
        if [ $k -eq 1 ]; then
            values_1="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,$runtime_ms,$throughput_ops,$third_value"
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            values_2="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,$runtime_ms,$throughput_ops,$third_value"
            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    if [ -z "$filtered_output" ]; then
        log "[WARN] No [INSERT|READ|UPDATE|SCAN|EXTEND] metrics found in $INPUT_FILE for phase=$phase epoch=$epoch run=$run."
    fi

    # Print the values to the output file
    [ -n "$values_1" ] && echo "$values_1" >> "$OUTPUT_FILE"
    [ -n "$values_2" ] && echo "$values_2" >> "$OUTPUT_FILE"

    echo "Arrangement completed. Output saved to $OUTPUT_FILE"
}

ensure_core_dependencies

# Clear previous logs/output for this run
> "$LOG_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")" "$(dirname "$OUTPUT_CSV")"
backup_workload_file
trap restore_workload_file EXIT
print_couchbase_debug_snapshot
preflight_couchbase_or_die

log "=== Executing the load phase ==="
phase="load"
epoch=0
run=0
source "$WORKLOAD_FILE"
recordcount=${recordcount:-""}
readallfields=${readallfields:-""}
requestdistribution=${requestdistribution:-""}
readproportion=${readproportion:-""}
updateproportion=${updateproportion:-""}
scanproportion=${scanproportion:-""}
insertproportion=${insertproportion:-""}
extendproportion=${extendproportion:-""}

run_ycsb_load
collect_couchbase_metrics
write_result "TRUE"

# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

for epoch in $(seq 1 3); do
    for run in $(seq 1 3); do
        # Set proportions for insert mode
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" "$WORKLOAD_FILE"

        recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        updatedoperationcount=$(echo "($extendoperationcount / 10)" | bc)

        # Change operation count for insert mode
        perl -i -p -e "s/^operationcount=.*/operationcount=$updatedoperationcount/" "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        run_ycsb_run

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        # Compute update record count
        updatedrecordcount=$(echo "$recordcount + ($extendoperationcount / 10)" | bc)

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^recordcount=.*/recordcount=$updatedrecordcount/" "$WORKLOAD_FILE"
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="spread-run"
        run_ycsb_run
        collect_couchbase_metrics
        write_result "FALSE"
    done
done

log "=== All steps completed. Results are logged in $LOG_FILE ==="
