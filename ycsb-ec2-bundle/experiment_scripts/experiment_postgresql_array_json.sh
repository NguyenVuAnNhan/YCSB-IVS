#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export YCSB_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$YCSB_HOME/bin:$PATH"

YCSB="../bin/ycsb.sh"

# DB names
DB_NAME="ycsb"
BACKUP_DB_NAME="ycsb_backup"
UNCHANGE_DB_NAME="ycsb_unchange"

# Path to the PostgreSQL data directory
DB_URL="jdbc:postgresql://localhost:5432/$DB_NAME"
JDBC_PROPERTIES="../jdbc-binding/conf/postgres.properties"
DB_USERNAME="ycsb"
DB_PWD="USyd2025"
BACKUP_URL="jdbc:postgresql://localhost:5432/$BACKUP_DB_NAME"
BACKUP_FILE="./ycsb_dump.sql"
UNCHANGE_DB_URL="jdbc:postgresql://localhost:5432/$UNCHANGE_DB_NAME"

# Change naming parameters here
TYPE="postgresql_arrayjson_TOAST"
DIST="zipfian" # "uniform" OR "zipfian"
SCALE="heavy" # "heavy" OR "light"
WORK="pure" # "mixed" OR "pure"
RUN="1"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_results.log"
OUTPUT_CSV="../analysis/postgresql_array_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/postgresql_array_output.csv"
OUTPUT_FILE="../analysis/Data/Workload_data/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}.csv"

# Key size gathering
KEY_SIZE_LOG="key_sizes_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}.csv"
KEY_SIZE_FILE_AFTER_EXTEND="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_before_${WORK}.csv"
KEY_SIZE_FILE_AFTER_RUN="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_after_${WORK}.csv"
HISTOGRAM_FILE="histogram.txt"

# VACUUM settings
vacuum=1

# Plan log file
PLAN_LOG="./${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_query_plan.log"
INTERNAL_DATA_DIR="../analysis/Data/Internal_data"
DETOAST_PROBE_LOG="${INTERNAL_DATA_DIR}/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}_detoast_probe.log"
DETOAST_PROBE_ENABLED=${DETOAST_PROBE_ENABLED:-1}
DETOAST_PROBE_EVERY=${DETOAST_PROBE_EVERY:-1}
DB_STATS_INTERVAL=${DB_STATS_INTERVAL:-60}

# Extend phase experiment parameters
extendproportion_extend="1"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="0"
readmodifywriteproportion_extend="0"
requestdistribution_extend="zipfian"
# Optional specific request distributions for each operation
readrequestdistribution_extend="uniform"
updaterequestdistribution_extend="uniform"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="1"
updateproportion_postextend="0"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"
# Optional specific request distributions for each operation
readrequestdistribution_postextend="uniform"
updaterequestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="100000"

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

collect_cpu_memory_metrics() {
    cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum + 0}')
    memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum + 0}')
}

# CPU and Memory watcher
run_with_metrics() {
    set +e
    local db_name=$1
    local phase=$2
    local epoch=$3
    local output_csv=$4

    shift 4

    metrics_file="../analysis/${db_name}_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_${phase}.metrics"
    db_stats_file="${INTERNAL_DATA_DIR}/${db_name}_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_${phase}.dbstats"

    echo "Starting metrics collection for $db_name"
    mkdir -p "$INTERNAL_DATA_DIR"

    # Start watcher
    setsid env \
        DB_PWD="$DB_PWD" \
        DB_USERNAME="$DB_USERNAME" \
        db_name="$db_name" \
        phase="$phase" \
        epoch="$epoch" \
        metrics_file="$metrics_file" \
        DB_STATS_FILE="$db_stats_file" \
        DB_STATS_TABLE="usertable" \
        DB_STATS_INTERVAL="$DB_STATS_INTERVAL" \
        INTERVAL=1 \
        ./watcher.sh &
    watcher_pid=$!

    trap "kill -TERM -$watcher_pid 2>/dev/null" EXIT INT TERM

    "$@" > "$output_csv"
    status=$?

    # Stop watcher
    kill -TERM -$watcher_pid 2>/dev/null
    wait $watcher_pid 2>/dev/null

    trap - EXIT INT TERM

    echo "Finished $db_name phase=$phase epoch=$epoch (exit=$status)"
    set -e
}

record_db_stats_once() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local metrics_file="../analysis/${db_name}_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_${phase_label}.metrics"
    local db_stats_file="${INTERNAL_DATA_DIR}/${db_name}_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_${phase_label}.dbstats"

    mkdir -p "$INTERNAL_DATA_DIR"
    env \
        DB_PWD="$DB_PWD" \
        DB_USERNAME="$DB_USERNAME" \
        db_name="$db_name" \
        phase="$phase_label" \
        epoch="$epoch_label" \
        metrics_file="$metrics_file" \
        DB_STATS_FILE="$db_stats_file" \
        DB_STATS_TABLE="usertable" \
        ONESHOT_DBSTATS=1 \
        ./watcher.sh
}

# Initialize PostgreSQL database
initialize_database() {
    local db_name="$1"
    log "Initializing PostgreSQL database $db_name..."

    PGPASSWORD="$DB_PWD" dropdb --if-exists "$db_name" -U "$DB_USERNAME"
    PGPASSWORD="$DB_PWD" createdb "$db_name" -U "$DB_USERNAME"

    PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" -c \
        "CREATE TABLE usertable (
            ycsb_key TEXT PRIMARY KEY,
            field0 JSONB, field1 JSONB, field2 JSONB, field3 JSONB, field4 JSONB,
            field5 JSONB, field6 JSONB, field7 JSONB, field8 JSONB, field9 JSONB
        );"

    log "Done initializing $db_name."
}

# Clear the log file and previous backups
> $LOG_FILE
> $PLAN_LOG
> $HISTOGRAM_FILE

mkdir -p "$INTERNAL_DATA_DIR"
> "$DETOAST_PROBE_LOG"

rm -rf $KEY_SIZE_LOG
rm -f "$KEY_SIZE_FILE_AFTER_EXTEND" "$KEY_SIZE_FILE_AFTER_RUN"
find "$INTERNAL_DATA_DIR" -maxdepth 1 -type f \
    -name "*${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}*.dbstats" -delete

initialize_database "$DB_NAME"
initialize_database "$UNCHANGE_DB_NAME"

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Filter for inserts, reads, updates, scans, and extends
    # Also catch the overall output
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")
    if [ "$first" == "TRUE" ]; then
        # Create header
        dynamic_cols=$(awk '{print $2}' <<< "$filtered_output" \
            | sed 's/,$//' \
            | grep -v '^Return=ERROR$' \
            | uniq \
            | awk '{ORS=","; print}' \
            | sed 's/,$//')
        if [ -n "$dynamic_cols" ]; then
            header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,CPU,Memory,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes,checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time,wal_bytes,wal_records,wal_fpi,wal_buffers_full,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec),$dynamic_cols"
        else
            header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,CPU,Memory,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes,checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time,wal_bytes,wal_records,wal_fpi,wal_buffers_full,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec)"
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
        r=$((10 * ($epoch - 1) + $run))
    fi

    # Set default values for workload parameters
    recordcount=${recordcount:-""}
    readallfields=${readallfields:-""}
    requestdistribution=${requestdistribution:-""}
    readrequestdistribution=${readrequestdistribution:-""}
    updaterequestdistribution=${updaterequestdistribution:-""}
    readproportion=${readproportion:-""}
    updateproportion=${updateproportion:-""}
    scanproportion=${scanproportion:-""}
    insertproportion=${insertproportion:-""}
    extendproportion=${extendproportion:-""}
    cpu=${cpu:-""}
    memory=${memory:-""}

    # Extract throughput from overall output
    run_specific=()
    while IFS= read -r inner_line; do
        # Extract third value
        tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
        run_specific+=("$tmp")
    done <<< "$overall_output"

    # Iterate through each line
    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
    # Initialize operation to empty
    operation=""
    while IFS= read -r line; do
        # Extract operation, metric label, and third value
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        metric_label=$(echo "$line" | awk '{print $2}' | sed 's/,$//')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')

        # Write the associated distribution for the operation
        if [ "$operation" = "READ" ] && [ -n "$readrequestdistribution" ]; then
            op_requestdistribution="$readrequestdistribution"
        elif [ "$operation" = "UPDATE" ] && [ -n "$updaterequestdistribution" ]; then
            op_requestdistribution="$updaterequestdistribution"
        else
            op_requestdistribution="$requestdistribution"
        fi

        # Build CSV row
        if [ $k -eq 1 ]; then
            values_1="$r,$phase,$recordcount,$readallfields,$op_requestdistribution,$operation,$cpu,$memory,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            values_2="$r,$phase,$recordcount,$readallfields,$op_requestdistribution,$operation,$cpu,$memory,$blks_read,$blks_hit,$tup_returned,$tup_fetched,$tup_inserted,$tup_updated,$tup_deleted,$deadlocks,$temp_files,$temp_bytes,$checkpoints_timed,$checkpoints_req,$buffers_checkpoint,$buffers_clean,$buffers_backend,$buffers_alloc,$checkpoint_write_time,$checkpoint_sync_time,$wal_bytes,$wal_records,$wal_fpi,$wal_buffers_full,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    # Print the values to the output file
    [ -n "$values_1" ] && echo "$values_1" >> "$OUTPUT_FILE"
    [ -n "$values_2" ] && echo "$values_2" >> "$OUTPUT_FILE"

    # Print completion message
    log "Arrangement completed. Output saved to $OUTPUT_FILE"

}

# Function to close the PostgreSQL database
close_db() {
    log "PostgreSQL backend: no manual DB close required."
}

# Function to append values for the first iteration
append_first_iteration() {
    local key_size_log="$1"
    local key_size_file="$2"

    log "Appending first iteration..."
    awk -F, 'NR==1 {next} {print $1 "," $2}' "$key_size_log" >> "$key_size_file"
    log "First iteration: Appended values from $key_size_log to $key_size_file"
}

# Function to append sizes for subsequent iterations
append_subsequent_iterations() {
    local key_size_log="$1"
    local key_size_file="$2"

    log "Appending subsequent iteration $iteration..."
    awk -F, -v iter="$iteration" '
        NR==FNR {if (NR > 1) {key_sizes[$1]=$2;} next}  # Read key_sizes from log
        FNR==1 {print $0 ",Run" iter; next}             # Add new run column in the header
        ($1 in key_sizes) {print $0 "," key_sizes[$1]}  # Append size for existing key
        !($1 in key_sizes) {print $0 ",0"}              # If key is not found, append 0
    ' "$key_size_log" "$key_size_file" > temp.csv

    mv temp.csv "$key_size_file"  # Overwrite the file with updated content
    log "Iteration $iteration: Appended new size values from $key_size_log to $key_size_file"
}

# Generate histogram from key size log
get_key_sizes() {
    local key_size_log="$1"
    local histogram_file="$2"

    log "Generating histogram from key size log: $key_size_log"

    awk -F, '
        BEGIN {
            block = 100
            OFS = "\t"
        }
        NR == 1 { next }  # Skip header
        {
            size = $2 + 0
            bucket = int(size / (block * 10 ))   #Converting value length to field length as there are 10 fields
            histogram[bucket]++
            if (bucket > max_bucket) max_bucket = bucket
        }
        END {
            print "BlockSize", block > "'"$histogram_file"'"
            for (i = 0; i <= max_bucket; i++) {
                count = (i in histogram) ? histogram[i] : 0
                print i, count >> "'"$histogram_file"'"
            }
        }
    ' "$key_size_log"

    log "Histogram written to $histogram_file (BlockSize = 100)"
}

# Function to extract PostgreSQL database and background writer statistics
collect_postgres_metrics() {
    local db="${1:-$DB_NAME}"

    # database-level stats
    read blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated tup_deleted deadlocks temp_files temp_bytes <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT blks_read, blks_hit, tup_returned, tup_fetched,
                   tup_inserted, tup_updated, tup_deleted, deadlocks,
                   temp_files, temp_bytes
            FROM pg_stat_database
            WHERE datname = '$db';
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    # bgwriter
    read checkpoints_timed checkpoints_req buffers_checkpoint buffers_clean buffers_backend buffers_alloc checkpoint_write_time checkpoint_sync_time <<< \
        $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
            SELECT checkpoints_timed, checkpoints_req,
                   buffers_checkpoint, buffers_clean,
                   buffers_backend, buffers_alloc,
                   checkpoint_write_time, checkpoint_sync_time
            FROM pg_stat_bgwriter;
        " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    # wal metrics
    if PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -c "\d pg_stat_wal" &>/dev/null; then
        read wal_bytes wal_records wal_fpi wal_buffers_full <<< \
            $(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db" -t -c "
                SELECT wal_bytes, wal_records, wal_fpi, wal_buffers_full
                FROM pg_stat_wal;
            " | tr '|' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
    else
        wal_bytes="0"; wal_records="0"; wal_fpi="0"; wal_buffers_full="0"
    fi
}

select_detoast_probe_keys() {
    local key_size_log="$1"
    local sorted_sizes
    local count
    local rank

    sorted_sizes=$(mktemp)
    awk -F, 'NR > 1 && $2 ~ /^[0-9]+$/ {print $2 "," $1}' "$key_size_log" \
        | sort -t, -k1,1n > "$sorted_sizes"

    count=$(wc -l < "$sorted_sizes" | tr -d ' ')
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        rm -f "$sorted_sizes"
        return
    fi

    emit_probe_key() {
        local label="$1"
        local rank="$2"
        local line
        local size
        local key

        line=$(sed -n "${rank}p" "$sorted_sizes")
        size=${line%%,*}
        key=${line#*,}
        printf '%s,%s,%s\n' "$label" "$key" "$size"
    }

    emit_probe_key "min" 1

    for label_quantile in "p50:0.50" "p90:0.90" "p95:0.95" "p99:0.99"; do
        label=${label_quantile%%:*}
        quantile=${label_quantile#*:}
        rank=$(awk -v n="$count" -v q="$quantile" 'BEGIN {
            r = int(n * q + 0.999999);
            if (r < 1) r = 1;
            if (r > n) r = n;
            print r;
        }')
        emit_probe_key "$label" "$rank"
    done

    emit_probe_key "max" "$count"
    rm -f "$sorted_sizes"
}

run_jsonb_detoast_probes() {
    local db_name="$1"
    local phase_label="$2"
    local epoch_label="$3"
    local key_size_log="$4"

    if [ "$DETOAST_PROBE_ENABLED" != "1" ]; then
        return
    fi

    if [ "$DETOAST_PROBE_EVERY" -gt 1 ] && [ $((epoch_label % DETOAST_PROBE_EVERY)) -ne 0 ]; then
        return
    fi

    if [ ! -s "$key_size_log" ]; then
        log "Skipping detoast probes: missing key size log $key_size_log"
        return
    fi

    mkdir -p "$INTERNAL_DATA_DIR"
    log "Running JSONB detoast probes for $db_name phase=$phase_label epoch=$epoch_label"

    while IFS=, read -r probe_label probe_key probe_size; do
        {
            echo "========================================"
            echo "Epoch=$epoch Run=$run Iteration=$epoch_label Phase=$phase_label Probe=$probe_label Time=$(date)"
            echo "DB=$db_name"
            echo "Key=$probe_key"
            echo "SizeBytes=$probe_size"
            echo "----------------------------------------"
            echo "Lookup-only probe"
            printf '%s\n' \
                "EXPLAIN (ANALYZE, BUFFERS)" \
                "SELECT ycsb_key" \
                "FROM usertable" \
                "WHERE ycsb_key = :'probe_key';" \
                | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" \
                    -v ON_ERROR_STOP=1 \
                    -v probe_key="$probe_key"
            echo
            echo "JSONB array-length detoast probe"
            printf '%s\n' \
                "EXPLAIN (ANALYZE, BUFFERS)" \
                "SELECT" \
                "    jsonb_array_length(COALESCE(field0, '[]'::jsonb)) +" \
                "    jsonb_array_length(COALESCE(field1, '[]'::jsonb)) +" \
                "    jsonb_array_length(COALESCE(field2, '[]'::jsonb)) +" \
                "    jsonb_array_length(COALESCE(field3, '[]'::jsonb)) +" \
                "    jsonb_array_length(COALESCE(field4, '[]'::jsonb)) +" \
                "    jsonb_array_length(COALESCE(field5, '[]'::jsonb)) +" \
                "    jsonb_array_length(COALESCE(field6, '[]'::jsonb)) +" \
                "    jsonb_array_length(COALESCE(field7, '[]'::jsonb)) +" \
                "    jsonb_array_length(COALESCE(field8, '[]'::jsonb)) +" \
                "    jsonb_array_length(COALESCE(field9, '[]'::jsonb)) AS jsonb_array_element_count" \
                "FROM usertable" \
                "WHERE ycsb_key = :'probe_key';" \
                | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" \
                    -v ON_ERROR_STOP=1 \
                    -v probe_key="$probe_key"
            echo
            echo "Detoast and JSONB serialization probe"
            printf '%s\n' \
                "EXPLAIN (ANALYZE, BUFFERS)" \
                "SELECT" \
                "    octet_length(field0::text) +" \
                "    octet_length(field1::text) +" \
                "    octet_length(field2::text) +" \
                "    octet_length(field3::text) +" \
                "    octet_length(field4::text) +" \
                "    octet_length(field5::text) +" \
                "    octet_length(field6::text) +" \
                "    octet_length(field7::text) +" \
                "    octet_length(field8::text) +" \
                "    octet_length(field9::text) AS logical_json_text_bytes" \
                "FROM usertable" \
                "WHERE ycsb_key = :'probe_key';" \
                | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$db_name" \
                    -v ON_ERROR_STOP=1 \
                    -v probe_key="$probe_key"
            echo
        } >> "$DETOAST_PROBE_LOG"
    done < <(select_detoast_probe_keys "$key_size_log")
}

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
epoch=0
run=0
# Extract workload parameters for load phase
source "$WORKLOAD_FILE"
recordcount=${recordcount:-""}
readallfields=${readallfields:-""}
requestdistribution=${requestdistribution:-""}
readrequestdistribution=${readrequestdistribution:-""}
updaterequestdistribution=${updaterequestdistribution:-""}
readproportion=${readproportion:-""}
updateproportion=${updateproportion:-""}
scanproportion=${scanproportion:-""}
insertproportion=${insertproportion:-""}
extendproportion=${extendproportion:-""}

run_with_metrics "$DB_NAME" "$phase" "$run" "$OUTPUT_CSV" \
    $YCSB load jdbc-array-json -s \
    -P $WORKLOAD_FILE \
    -P $JDBC_PROPERTIES \
    -p db.url="$DB_URL" \
    -p db.user="$DB_USERNAME" \
    -p db.passwd="$DB_PWD"
cpu=$(ps -u postgres -o %cpu= | awk '{sum += $1} END {print sum}')
memory=$(ps -u postgres -o %mem= | awk '{sum += $1} END {print sum}')
total_size_initial_load=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -At -F"," -c "SELECT SUM(COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field0, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field1, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field2, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field3, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field4, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field5, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field6, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field7, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field8, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field9, '[]'::jsonb)) AS elem(value)), 0)) FROM usertable;")
log "Initial-load verification - TotalSize:$total_size_initial_load ExpectedFieldLength:$fieldlengthoriginal"
collect_postgres_metrics $DB_NAME
write_result "TRUE"

# Load unchange value size (reference) DB
run_with_metrics "$UNCHANGE_DB_NAME" "$phase" "$run" "$OUTPUT_CSV" \
    $YCSB load jdbc-array-json -s \
    -P $WORKLOAD_FILE \
    -P $JDBC_PROPERTIES \
    -p db.url="$UNCHANGE_DB_URL" \
    -p db.user="$DB_USERNAME" \
    -p db.passwd="$DB_PWD"

total_size_reference_load=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$UNCHANGE_DB_NAME" -At -F"," -c "SELECT SUM(COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field0, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field1, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field2, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field3, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field4, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field5, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field6, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field7, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field8, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field9, '[]'::jsonb)) AS elem(value)), 0)) FROM usertable;")
log "Reference-load verification - TotalSize:$total_size_reference_load ExpectedFieldLength:$fieldlengthoriginal"

# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

# Experiment parameters
for epoch in $(seq 1 10); do
    for run in $(seq 1 10); do

        iteration=$((10*($epoch-1)+$run))
        
        # Setting parameter values for extend phase
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readrequestdistribution=.*/readrequestdistribution=$readrequestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updaterequestdistribution=.*/updaterequestdistribution=$updaterequestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$extendoperationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"
        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readrequestdistribution=${readrequestdistribution:-""}
        updaterequestdistribution=${updaterequestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Execute the extend phase
        log "=== Executing the extend phase with extendproportion=1 and other proportions=0 ==="
        phase="extend"
        # Capture both stdout and stderr to capture status messages
        run_with_metrics "$DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
            $YCSB run jdbc-array-json -s \
            -P $WORKLOAD_FILE \
            -P $JDBC_PROPERTIES \
            -p db.url="$DB_URL" \
            -p db.user="$DB_USERNAME" \
            -p db.passwd="$DB_PWD" \
            -p fieldlengthhistogram="$HISTOGRAM_FILE"
        
        # Extract extend failure count from YCSB output (status messages are in the output)
        extend_failed_count=$(grep -oP 'EXTEND-FAILED: Count=\K\d+' "$OUTPUT_CSV" | head -1 || echo "0")
        if [ -n "$extend_failed_count" ] && [ "$extend_failed_count" != "0" ]; then
            log "WARNING: $extend_failed_count EXTEND operations failed during extend phase"
        fi
        
        collect_cpu_memory_metrics
        collect_postgres_metrics $DB_NAME
        write_result "FALSE"

        # Key Sizes
        log "Size computation started"
        echo "ycsb_key,size" > "$KEY_SIZE_LOG"
        PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -At -F"," \
        -c "SELECT ycsb_key,
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field0, '[]'::jsonb)) AS elem(value)), 0) +
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field1, '[]'::jsonb)) AS elem(value)), 0) +
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field2, '[]'::jsonb)) AS elem(value)), 0) +
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field3, '[]'::jsonb)) AS elem(value)), 0) +
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field4, '[]'::jsonb)) AS elem(value)), 0) +
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field5, '[]'::jsonb)) AS elem(value)), 0) +
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field6, '[]'::jsonb)) AS elem(value)), 0) +
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field7, '[]'::jsonb)) AS elem(value)), 0) +
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field8, '[]'::jsonb)) AS elem(value)), 0) +
            COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field9, '[]'::jsonb)) AS elem(value)), 0) AS size
            FROM usertable;" \
        >> "$KEY_SIZE_LOG"
        
        # Verify extend operations: check min, max, avg sizes to detect extension failures
        extend_stats=$(awk -F, '
            NR == 1 { next }
            {
                sizes[NR-1] = $2
                sum += $2
                count++
            }
            END {
                if (count > 0) {
                    avg = sum / count
                    min = sizes[1]
                    max = sizes[1]
                    for (i = 2; i <= count; i++) {
                        if (sizes[i] < min) min = sizes[i]
                        if (sizes[i] > max) max = sizes[i]
                    }
                    printf "Min:%d Max:%d Avg:%.0f", min, max, avg
                }
            }
        ' "$KEY_SIZE_LOG")
        log "Extend verification - $extend_stats (Expected avg per record: ~$((10 * fieldlengthoriginal)) bytes initially)"

        get_key_sizes $KEY_SIZE_LOG $HISTOGRAM_FILE

        # Check if the output file exists, if not, create it with headers
        iteration=$((10*($epoch-1)+$run))

        if [[ ! -f "$KEY_SIZE_FILE_AFTER_EXTEND" ]]; then
            # Add header row
            echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_EXTEND"
        fi

        # If it's the first iteration, append keys and sizes for the first run
        if [[ "$iteration" -eq 1 ]]; then
            append_first_iteration $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_EXTEND
        else
            append_subsequent_iterations $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_EXTEND
        fi

        if [[ $vacuum -eq 1 ]]; then
            log "VACUUM start: $(date +%s)"
            PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -c "VACUUM (ANALYZE, VERBOSE) usertable;"
            log "VACUUM end: $(date +%s)"
            record_db_stats_once "$DB_NAME" "post-vacuum" "$iteration"
        else
            record_db_stats_once "$DB_NAME" "post-extend-no-vacuum" "$iteration"
        fi

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readrequestdistribution=.*/readrequestdistribution=$readrequestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updaterequestdistribution=.*/updaterequestdistribution=$updaterequestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" $WORKLOAD_FILE
        grep -q '^fieldlengthdistribution=' "$WORKLOAD_FILE" || echo -e "\nfieldlengthdistribution=histogram" >> "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readrequestdistribution=${readrequestdistribution:-""}
        updaterequestdistribution=${updaterequestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Save the existing keys in the database
        PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_before_run.txt

        # Log query plan before run phase
        log "Checking query plan before run phase"

        TEST_KEY=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -At -c \
        "SELECT ycsb_key FROM usertable LIMIT 1;")

        {
            echo "========================================"
            echo "Epoch=$epoch Run=$run Phase=run Time=$(date)"
            echo "DB=$DB_NAME"
            echo "Key=$TEST_KEY"
            echo "----------------------------------------"

            PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -c "
            EXPLAIN (ANALYZE, BUFFERS)
            SELECT * FROM usertable WHERE ycsb_key = '$TEST_KEY';
            "

            echo
        } >> "$PLAN_LOG"

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="run"
        run_with_metrics "$DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
        $YCSB run jdbc-array-json -s \
        -P $WORKLOAD_FILE \
        -P $JDBC_PROPERTIES \
        -p db.url="$DB_URL" \
        -p db.user="$DB_USERNAME" \
        -p db.passwd="$DB_PWD" \
        -p fieldlengthhistogram="$HISTOGRAM_FILE"
        
        collect_cpu_memory_metrics
        collect_postgres_metrics $DB_NAME
        write_result "FALSE"
        record_db_stats_once "$DB_NAME" "post-run" "$iteration"
        run_jsonb_detoast_probes "$DB_NAME" "post-run" "$iteration" "$KEY_SIZE_LOG"

        # Save keys to remove duplicates later
        PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_after_run.txt

        # Sort both files
        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but not in keys.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Delete keys from PostgreSQL
        KEYS_TO_DELETE_FILE="$(pwd)/keys_to_delete.txt"
        while read key; do
            echo "DELETE FROM usertable WHERE ycsb_key='$key';"
        done < "$KEYS_TO_DELETE_FILE" | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$DB_NAME"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt

        PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$UNCHANGE_DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_before_run.txt

        # Reference workload with unchanging value sizes
        phase="reference"
        run_with_metrics "$UNCHANGE_DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
        $YCSB run jdbc-array-json -s \
        -P $WORKLOAD_FILE \
        -P $JDBC_PROPERTIES \
        -p db.url="$UNCHANGE_DB_URL" \
        -p db.user="$DB_USERNAME" \
        -p db.passwd="$DB_PWD" \
        -p fieldlengthhistogram="$HISTOGRAM_FILE"
        
        collect_cpu_memory_metrics
        collect_postgres_metrics $UNCHANGE_DB_NAME
        write_result "FALSE"

        # Save keys to remove duplicates later
        PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$UNCHANGE_DB_NAME" -At -F"," \
        -c "SELECT ycsb_key
            FROM usertable;" > keys_after_run.txt

        # Sort both files
        sort keys_before_run.txt > keys_before_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but not in keys.txt
        comm -13 keys_before_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Delete keys from PostgreSQL
        KEYS_TO_DELETE_FILE="$(pwd)/keys_to_delete.txt"
        while read key; do
            echo "DELETE FROM usertable WHERE ycsb_key='$key';"
        done < "$KEYS_TO_DELETE_FILE" | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$UNCHANGE_DB_NAME"

        rm -rf keys_after_run.txt keys_before_run.txt keys_before_sorted.txt keys_after_sorted.txt keys_to_delete.txt
    
        if (( $((10*($epoch-1)+$run)) % 1 == 0 )); then
            phase="clean-run"
            
            log "Backing up the database started"
            PGPASSWORD="$DB_PWD" dropdb --if-exists "$BACKUP_DB_NAME" -U "$DB_USERNAME"
            PGPASSWORD="$DB_PWD" createdb "$BACKUP_DB_NAME" -U "$DB_USERNAME"

            # Dump primary DB into file with --clean to include DROP statements
            PGPASSWORD="$DB_PWD" pg_dump -U "$DB_USERNAME" -d "$DB_NAME" --clean > "$BACKUP_FILE"

            # Restore backup - --clean ensures tables are dropped before creation
            PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$BACKUP_DB_NAME" -f "$BACKUP_FILE" > /dev/null 2>&1 || true
            log "Backing up the database finished"

            run_with_metrics "$BACKUP_DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
                $YCSB run jdbc-array-json -s \
                -P $WORKLOAD_FILE \
                -P $JDBC_PROPERTIES \
                -p db.url="$BACKUP_URL" \
                -p db.user="$DB_USERNAME" \
                -p db.passwd="$DB_PWD" \
                -p fieldlengthhistogram="$HISTOGRAM_FILE"

            collect_cpu_memory_metrics
            collect_postgres_metrics $BACKUP_DB_NAME
            rm -rf "$BACKUP_FILE"
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            log "Size computation started"
            echo "ycsb_key,size" > "$KEY_SIZE_LOG"
            PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$BACKUP_DB_NAME" -At -F"," \
            -c "SELECT ycsb_key,
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field0, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field1, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field2, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field3, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field4, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field5, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field6, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field7, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field8, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field9, '[]'::jsonb)) AS elem(value)), 0) AS size
                FROM usertable;" \
            >> "$KEY_SIZE_LOG"
            
            # Check if the output file exists, if not, create it with headers
            if [[ ! -f "$KEY_SIZE_FILE_AFTER_RUN" ]]; then
                # Add header row
                echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            # If it's the first iteration, append keys and sizes for the first run
            if [[ "$iteration" -eq 1 ]]; then
                append_first_iteration $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_RUN
            else
                append_subsequent_iterations $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_RUN
            fi

            # Extract the recordcount from the workload file
            recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

            # PostgreSQL query to get the total size of all records
            total_size=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$BACKUP_DB_NAME" -At -F"," \
            -c "SELECT SUM(
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field0, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field1, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field2, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field3, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field4, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field5, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field6, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field7, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field8, '[]'::jsonb)) AS elem(value)), 0) +
                COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field9, '[]'::jsonb)) AS elem(value)), 0)
            ) FROM usertable;")

            # Set average field length
            if [ -z "$total_size" ] || [ -z "$recordcount" ] || [ "$recordcount" -eq 0 ]; then
                log "Warning: Cannot calculate fieldlengthaverage - total_size=$total_size, recordcount=$recordcount"
                fieldlengthaverage="$fieldlengthoriginal"
            else
                fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)
            fi

            log "Total size: $total_size, Field length average: $fieldlengthaverage"

            # Changing the value size for comparison
            if grep -q '^fieldlength=' "$WORKLOAD_FILE"; then
                perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" $WORKLOAD_FILE
            else
                echo "fieldlength=$fieldlengthaverage" >> "$WORKLOAD_FILE"
            fi
            source "$WORKLOAD_FILE"
            # Verify fieldlength was set correctly
            actual_fieldlength=$(grep -E '^fieldlength=' "$WORKLOAD_FILE" | cut -d'=' -f2)
            log "Workload file fieldlength set to: $actual_fieldlength (expected: $fieldlengthaverage)"

            PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$BACKUP_DB_NAME" \
            -c "TRUNCATE TABLE usertable;"

            # Resetting the database with new data load
            log "=== Executing the load phase for the comparison study ==="
            $YCSB load jdbc-array-json -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$BACKUP_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV
            total_size_comparison_load=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$BACKUP_DB_NAME" -At -F"," -c "SELECT SUM(COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field0, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field1, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field2, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field3, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field4, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field5, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field6, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field7, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field8, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field9, '[]'::jsonb)) AS elem(value)), 0)) FROM usertable;")
            log "Comparison-load verification - Epoch:$epoch Run:$run TotalSize:$total_size_comparison_load ExpectedFieldLength:$fieldlengthaverage"
            
            # Verify record sizes after avg-run load
            total_size_avg_run=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d "$BACKUP_DB_NAME" -At -F"," -c "SELECT SUM(COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field0, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field1, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field2, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field3, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field4, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field5, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field6, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field7, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field8, '[]'::jsonb)) AS elem(value)), 0) + COALESCE((SELECT SUM(octet_length(value)) FROM jsonb_array_elements_text(COALESCE(field9, '[]'::jsonb)) AS elem(value)), 0)) FROM usertable;")
            log "Avg-run verification - Epoch:$epoch Run:$run Iteration:$iteration TotalSize:$total_size_avg_run ExpectedFieldLength:$fieldlengthaverage"
            
            # Chainging the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthoriginal/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            # Execute the run phase
            log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
            phase="avg-run"

            run_with_metrics "$BACKUP_DB_NAME" "$phase" "${iteration}" "$OUTPUT_CSV" \
                $YCSB run jdbc-array-json -s \
                -P $WORKLOAD_FILE \
                -P $JDBC_PROPERTIES \
                -p db.url="$BACKUP_URL" \
                -p db.user="$DB_USERNAME" \
                -p db.passwd="$DB_PWD"
            
            collect_cpu_memory_metrics
            collect_postgres_metrics $BACKUP_DB_NAME
            write_result "FALSE"
        fi
    done
done

# Delete intermediate temp files
# rm -rf $LOG_FILE
# rm -rf $OUTPUT_CSV
# rm -rf $KEY_SIZE_LOG

log "=== All steps completed. Results are logged in $LOG_FILE ==="
