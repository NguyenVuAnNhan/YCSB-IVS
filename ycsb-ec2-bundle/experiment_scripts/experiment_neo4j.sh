#!/bin/bash

###### Neo4j-specific helpers and database functions ######

assert_bolt_uri() {
    if [[ -z "$1" || "$1" != bolt://* ]]; then
        echo "ERROR: invalid or empty Bolt URI: '$1'" >&2
        return 1
    fi
}

assert_neo4j_uri() {
    if [[ -z "$1" || "$1" != neo4j://* ]]; then
        echo "ERROR: invalid or empty Neo4j URI: '$1'" >&2
        return 1
    fi
}

# Run a Cypher statement against a specific Neo4j database
run_cypher() {
    local bolt_uri="$1"
    local query="$2"
    shift 2 || true

    assert_bolt_uri "$bolt_uri" || return 1

    cypher-shell \
        -u "$DB_USERNAME" \
        -p "$DB_PWD" \
        -a "$bolt_uri" \
        "$query" "$@"
}

# Create the main YCSB label + constraint on a given instance
create_table() {
    local bolt_uri="$1"

    run_cypher "$bolt_uri" \
        "CREATE CONSTRAINT usertable_id IF NOT EXISTS
         FOR (n:usertable)
         REQUIRE n.id IS UNIQUE;" \
        >/dev/null 2>&1 || true
}

# Define database-specific binding field names (metrics collected from Neo4j)
# These should match the variable names set by collect_neo4j_metrics() function
binding_field_names=(
    "transaction_commits"
    "transaction_rollbacks"
    "nodes_created"
    "nodes_deleted"
    "relationships_created"
    "relationships_deleted"
    "properties_set"
    "index_hits"
    "index_misses"
    "lock_acquisition_time"
    "lock_wait_time"
    "checkpoint_total_time"
    "checkpoint_total_events"
    "log_rotation_events"
    "log_rotation_total_time"
    "transaction_started"
    "transaction_peak_concurrent"
    "transaction_active"
    "transaction_terminated"
)

# Function to close the database
close_db() {
    log "Neo4j backend: no manual DB close required."
}

# Function to extract Neo4j database statistics
# For simplicity and robustness, if any metric query fails, we default to 0.
collect_neo4j_metrics() {
    local bolt_uri="${1:-$MAIN_BOLT_URI}"

    # ---- defaults ----
    transaction_commits="0"
    transaction_rollbacks="0"
    transaction_peak_concurrent="0"
    transaction_active="0"
    nodes_created="0"
    nodes_deleted="0"
    relationships_created="0"
    relationships_deleted="0"
    properties_set="0"
    index_hits="0"
    index_misses="0"
    lock_acquisition_time="0"
    lock_wait_time="0"
    checkpoint_total_time="0"
    checkpoint_total_events="0"
    log_rotation_events="0"
    log_rotation_total_time="0"
    transaction_started="0"
    transaction_terminated="0"


    # ---- TRANSACTION COUNTS ----
    tx_active_raw=$(run_cypher "$bolt_uri" \
        "SHOW TRANSACTIONS YIELD transactionId RETURN count(*) AS count;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$tx_active_raw" ]]; then
        transaction_active="$tx_active_raw"
    else
        log "[METRIC-ERR] SHOW TRANSACTIONS failed on $bolt_uri"
    fi


    # ---- GRAPH COUNTS (nodes, rels, props) ----
    graph_counts_raw=$(run_cypher "$bolt_uri" \
        "CALL db.stats.retrieve('GRAPH COUNTS')
         YIELD section, data
         UNWIND data AS row
         RETURN
           reduce(total = 0, x IN row.nodes | total + x.count) AS nodes,
           reduce(total = 0, x IN row.relationships | total + x.count) AS relationships,
           reduce(total = 0, x IN row.properties | total + x.count) AS properties;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$graph_counts_raw" && "$graph_counts_raw" != "NULL|NULL|NULL" ]]; then
        nodes_created=$(cut -d'|' -f1 <<<"$graph_counts_raw")
        relationships_created=$(cut -d'|' -f2 <<<"$graph_counts_raw")
        properties_set=$(cut -d'|' -f3 <<<"$graph_counts_raw")
    else
        log "[METRIC-ERR] Graph counts unavailable on $bolt_uri"
    fi




    # ---- INDEX STATS (best-effort) ----
    index_stats_raw=$(run_cypher "$bolt_uri" \
        "SHOW INDEXES YIELD readCount, trackedSince
         RETURN sum(readCount) AS reads;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$index_stats_raw" && "$index_stats_raw" != "NULL" ]]; then
        index_hits="$index_stats_raw"
    else
        log "[METRIC-ERR] Index stats unavailable on $bolt_uri"
    fi


    # ---- COMMIT / ROLLBACK COUNTS (approx via logs) ----
    tx_counts_raw=$(run_cypher "$bolt_uri" \
        "SHOW TRANSACTIONS YIELD status
         RETURN
           sum(CASE WHEN status = 'Committed' THEN 1 ELSE 0 END) AS commits,
           sum(CASE WHEN status = 'RolledBack' THEN 1 ELSE 0 END) AS rollbacks;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$tx_counts_raw" && "$tx_counts_raw" != "NULL|NULL" ]]; then
        transaction_commits=$(cut -d'|' -f1 <<<"$tx_counts_raw")
        transaction_rollbacks=$(cut -d'|' -f2 <<<"$tx_counts_raw")
    else
        log "[METRIC-ERR] Transaction commit/rollback stats unavailable on $bolt_uri"
    fi
}

# Database-specific function to get key sizes (appends to file, caller should create header)
get_key_sizes_from_db() {
    local bolt_uri="$1"
    local key_size_log="$2"

    run_cypher "$bolt_uri" \
        "MATCH (n:usertable)
         RETURN n.id AS ycsb_key,
                reduce(total = 0, k IN ['field0','field1','field2','field3','field4','field5','field6','field7','field8','field9'] |
                    total + CASE WHEN n[k] IS NOT NULL THEN size(toString(n[k])) ELSE 0 END) AS size
         ORDER BY n.id;" \
        2>/dev/null | tail -n +2 | sed 's/|/,/' >> "$key_size_log"
}

# Database-specific function to get total size
get_total_size_from_db() {
    local bolt_uri="$1"

    run_cypher "$bolt_uri" \
        "MATCH (n:usertable)
         RETURN sum(reduce(total = 0, k IN ['field0','field1','field2','field3','field4','field5','field6','field7','field8','field9'] |
            total + CASE WHEN n[k] IS NOT NULL THEN size(toString(n[k])) ELSE 0 END)) AS total;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' '
}

# Database-specific function to get keys from database
get_keys_from_db() {
    local bolt_uri="$1"
    local output_file="$2"

    run_cypher "$bolt_uri" \
        "MATCH (n:usertable) RETURN n.id AS ycsb_key;" \
        2>/dev/null | tail -n +2 | sed 's/|//' > "$output_file"
}

# Database-specific function to delete keys
delete_batch_neo4j() {
    local bolt_uri="$1"
    local batch_file="$2"

    # Convert batch file → JSON array ["k1","k2",...]
    local keys_json
    keys_json=$(jq -R . < "$batch_file" | jq -s .)

    cypher-shell \
        -u "$DB_USERNAME" \
        -p "$DB_PWD" \
        -a "$bolt_uri" \
        --fail-at-end \
        <<EOF
UNWIND $keys_json AS k
MATCH (n:usertable {id: k})
DETACH DELETE n;
EOF
}

# Database-specific function to backup database
backup_instance() {
    local source_home="$1"     # e.g. /opt/neo4j-instance-main
    local source_data="$2"     # e.g. data-main
    local target_home="$3"     # e.g. /opt/neo4j-instance-backup
    local target_data="$4"     # e.g. data-backup

    log "Stopping Neo4j source + target for backup..."
    sudo -u neo4j "$source_home/bin/neo4j" stop || true
    sudo -u neo4j "$target_home/bin/neo4j" stop || true

    log "Copying data dir snapshot..."
    sudo -u neo4j rm -rf "$target_home/$target_data"/*
    sudo -u neo4j rsync -a --delete --no-times \
    "$source_home/$source_data"/ \
    "$target_home/$target_data"/
    sync


    log "Seeding password on backup instance..."
    sudo -u neo4j "$target_home/bin/neo4j-admin" dbms set-initial-password "$DB_PWD"

    log "Starting Neo4j source + target..."
    sudo -u neo4j "$source_home/bin/neo4j" start
    sudo -u neo4j "$target_home/bin/neo4j" start
}

measure_stats() {
    local bolt_uri="${1:-$MAIN_BOLT_URI}"
    local pid

    assert_bolt_uri "$bolt_uri" || return 1

    pid=$(lsof -iTCP -sTCP:LISTEN -P \
        | awk -v port="${bolt_uri##*:}" '$0 ~ port {print $2; exit}')

    if [[ -z "$pid" ]]; then
        echo "WARN: Could not resolve PID for $bolt_uri" >&2
        cpu=0
        memory=0
    else
        cpu=$(ps -p "$pid" -o %cpu= | tr -d ' ')
        memory=$(ps -p "$pid" -o %mem= | tr -d ' ')
    fi

    collect_neo4j_metrics "$bolt_uri"
}

run_ycsb_load() {
    local neo4j_uri="${1:-$MAIN_NEO4J_URI}"

    assert_neo4j_uri "$neo4j_uri" || return 1

    $YCSB load neo4j -s -P "$WORKLOAD_FILE" \
        -p url="$neo4j_uri" \
        -p username="$DB_USERNAME" \
        -p password="$DB_PWD" \
        > "$OUTPUT_CSV"
}

run_ycsb_run() {
    local neo4j_uri="${1:-$MAIN_NEO4J_URI}"
    local extra_params="${2:-}"

    assert_neo4j_uri "$neo4j_uri" || return 1

    $YCSB run neo4j -s -P "$WORKLOAD_FILE" \
        -p url="$neo4j_uri" \
        -p username="$DB_USERNAME" \
        -p password="$DB_PWD" \
        $extra_params \
        > "$OUTPUT_CSV"
}

#----------------------------------------------------------#

######Constants######

YCSB="../bin/ycsb.sh"

# Logical roles (each = separate Neo4j instance)
MAIN_NAME="ycsb"
BACKUP_NAME="ycsb-backup"
UNCHANGE_NAME="ycsb-unchange"

# Ports per instance
MAIN_BOLT_PORT=7687
BACKUP_BOLT_PORT=7787
UNCHANGE_BOLT_PORT=7887

# HTTP ports (optional, for browser/debug)
MAIN_HTTP_PORT=7474
BACKUP_HTTP_PORT=7574
UNCHANGE_HTTP_PORT=7674

# Credentials
DB_USERNAME="neo4j"
DB_PWD="password"

# Bolt URIs
MAIN_BOLT_URI="bolt://localhost:${MAIN_BOLT_PORT}"
BACKUP_BOLT_URI="bolt://localhost:${BACKUP_BOLT_PORT}"
UNCHANGE_BOLT_URI="bolt://localhost:${UNCHANGE_BOLT_PORT}"

# Neo4j URIs (for drivers that require neo4j://)
MAIN_NEO4J_URI="neo4j://localhost:${MAIN_BOLT_PORT}"
BACKUP_NEO4J_URI="neo4j://localhost:${BACKUP_BOLT_PORT}"
UNCHANGE_NEO4J_URI="neo4j://localhost:${UNCHANGE_BOLT_PORT}"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_neo4j_results.log"
QUERY_PLAN_LOG="./neo4j_query_plan.log"
OUTPUT_CSV="../analysis/neo4j_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/neo4j_output.csv"
OUTPUT_FILE="../analysis/Data/Workload_data/neo4j_run1_uniform_light_mixed.csv"

# Key size gathering
KEY_SIZE_LOG="key_sizes.csv"
KEY_SIZE_FILE_AFTER_EXTEND="../analysis/Data/Value_size_data/value_sizes_neo4j_run1_uniform_light_before_mixed.csv"
KEY_SIZE_FILE_AFTER_RUN="../analysis/Data/Value_size_data/value_sizes_neo4j_run1_uniform_light_after_mixed.csv"
HISTOGRAM_FILE="histogram.txt"

# Extend phase experiment parameters
extendproportion_extend="1"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="0"
readmodifywriteproportion_extend="0"
requestdistribution_extend="uniform"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="0.5"
updateproportion_postextend="0.5"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="5000"

#----------------------------------------------------------#

######Helper functions######

# Generate stats_header from binding_field_names
stats_header=$(IFS=','; echo "${binding_field_names[*]}")

# Constant headers (not database-specific)
common_header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation"
prop_header="Readprop,Updateprop,Scanprop,Insertprop,Extendprop"
runtime_header="Runtime(ms),Throughput(ops/sec)"

extract_dynamic_fields() {
    local filtered_output="$1"
    awk '{print $2}' <<< "$filtered_output" \
    | sed 's/,$//' \
    | uniq \
    | awk '{ORS=","; print}' \
    | sed 's/,$//'
}

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Remove rows not starting with specific operations and filter specific operations
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    # Extract Return=ERROR lines
    return_error_output=$(awk '/Return=ERROR/' "$INPUT_FILE" 2>/dev/null || echo "")

    if [ "$first" == "TRUE" ]; then   
        # Extract unique second values (except the first one) and create header
        dynamic_cols=$(awk '{print $2}' <<< "$filtered_output" | sed 's/,$//' | uniq | awk '{ORS=","; print}' | sed 's/,$//')
        if [ -n "$dynamic_cols" ]; then
            header="$common_header,$stats_header,$prop_header,$runtime_header,RETURN=ERROR,$dynamic_cols"
        else
            header="$common_header,$stats_header,$prop_header,$runtime_header,RETURN=ERROR"
        fi
        echo "$header" > "$OUTPUT_FILE"
    fi

    # Set default values for epoch and run if not set (e.g., during load phase)
    epoch=${epoch:-0}
    run=${run:-0}
    # Sanitize epoch and run to ensure they're single integers (take first line only, remove whitespace)
    epoch=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
    run=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
    # Handle load phase: use 0 instead of negative value
    if [ "$phase" == "load" ]; then
        r=0
    else
        r=$((10 * (epoch - 1) + run))
    fi

    # Set default values for workload parameters if not set
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
        # Extract third value (the metric value)
        tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
        run_specific+=("$tmp")
    done <<< "$overall_output"

    # Extract Return=ERROR value (third field from Return=ERROR line)
    return_error_value=""
    if [ -n "$return_error_output" ]; then
        return_error_value=$(echo "$return_error_output" | awk '{print $3}' | sed 's/,$//' | head -1)
    fi
    return_error_value=${return_error_value:-"0"}

    # Iterate through each line
    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
    # Initialize operation to empty in case filtered_output is empty
    operation=""
    while IFS= read -r line; do
        # Extract operation and third value
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')

        # Populate field arrays dynamically
        common_fields=(
            "$r"
            "$phase"
            "$recordcount"
            "$readallfields"
            "$requestdistribution"
            "$operation"
        )

        # Populate binding_fields from database-specific metrics using binding_field_names
        binding_fields=()
        for field_name in "${binding_field_names[@]}"; do
            # Use indirect variable reference to get the value
            binding_fields+=("${!field_name}")
        done

        prop_fields=(
            "$readproportion"
            "$updateproportion"
            "$scanproportion"
            "$insertproportion"
            "$extendproportion"
        )

        dynamic_fields=("${run_specific[@]}" "$return_error_value" "$third_value")

        # Append to the values variable
        if [ $k -eq 1 ]; then
            row_fields=(
                "${common_fields[@]}"
                "${binding_fields[@]}"
                "${prop_fields[@]}"
                "${dynamic_fields[@]}"
            )

            # join with commas (use subshell to avoid affecting global IFS)
            values_1=$(IFS=','; echo "${row_fields[*]}")

            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            row_fields=(
                "${common_fields[@]}"
                "${binding_fields[@]}"
                "${prop_fields[@]}"
                "${dynamic_fields[@]}"
            )

            # join with commas (use subshell to avoid affecting global IFS)
            values_2=$(IFS=','; echo "${row_fields[*]}")

            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    # Print the values to the output file (only if not empty)
    [ -n "$values_1" ] && echo "$values_1" >> "$OUTPUT_FILE"
    [ -n "$values_2" ] && echo "$values_2" >> "$OUTPUT_FILE"

    # Print completion message
    echo "Arrangement completed. Output saved to $OUTPUT_FILE"

}

# Function to append values for the first iteration
append_first_iteration() {
    local key_size_log="$1"
    local key_size_file="$2"

    echo "Appending first iteration..."
    awk -F, 'NR==1 {next} {print $1 "," $2}' "$key_size_log" >> "$key_size_file"
    echo "First iteration: Appended values from $key_size_log to $key_size_file"
}

# Function to append sizes for subsequent iterations
append_subsequent_iterations() {
    local key_size_log="$1"
    local key_size_file="$2"

    echo "Appending subsequent iteration $iteration..."
    awk -F, -v iter="$iteration" '
        NR==FNR {if (NR > 1) {key_sizes[$1]=$2;} next}  # Read key_sizes from log
        FNR==1 {print $0 ",Run" iter; next}             # Add new run column in the header
        ($1 in key_sizes) {print $0 "," key_sizes[$1]}  # Append size for existing key
        !($1 in key_sizes) {print $0 ",0"}              # If key is not found, append 0
    ' "$key_size_log" "$key_size_file" > temp.csv

    mv temp.csv "$key_size_file"  # Overwrite the file with updated content
    echo "Iteration $iteration: Appended new size values from $key_size_log to $key_size_file"
}

get_key_sizes() {
    local key_size_log="$1"
    local histogram_file="$2"

    echo "Generating histogram from key size log: $key_size_log"

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

    echo "Histogram written to $histogram_file (BlockSize = 100)"
}

delete_new_keys() {
    local bolt_uri="$1"

    if [[ -z "$bolt_uri" ]]; then
        echo "ERROR: delete_new_keys requires a Bolt URI" >&2
        return 1
    fi

    local keys_before_file="keys.txt"
    local keys_after_file="keys_after_run.txt"
    local keys_to_delete_file="keys_to_delete.txt"

    # Sort the key files
    sort "$keys_before_file" > keys_sorted.txt
    sort "$keys_after_file" > keys_after_sorted.txt

    # Find keys that are only in keys_after_run.txt
    comm -13 keys_sorted.txt keys_after_sorted.txt > "$keys_to_delete_file"

    local delete_count
    delete_count=$(wc -l < "$keys_to_delete_file" | tr -d ' ')

    echo "Deleting $delete_count new keys from Neo4j instance at '$bolt_uri'..."

    # Delete those keys
    local BATCH_SIZE=1000

    if [ ! -s "$keys_to_delete_file" ]; then
        echo "No new keys to delete."
    else
        split -l "$BATCH_SIZE" "$keys_to_delete_file" keys_batch_
        for f in keys_batch_*; do
            echo "Deleting batch: $f"
            delete_batch_neo4j "$bolt_uri" "$f"
        done
    fi

    if [ -s "$keys_to_delete_file" ]; then
        rm -f keys_batch_*
    fi

    rm -rf \
        "$keys_after_file" \
        "$keys_before_file" \
        keys_sorted.txt \
        keys_after_sorted.txt \
        "$keys_to_delete_file"

    echo "✅ Deletion complete for instance $bolt_uri."
}

# Initialize database
initialize_database() {
    local db_name="$1"

    local bolt_uri
    local data_dir
    local neo4j_home

    case "$db_name" in
        ycsb)
            bolt_uri="$MAIN_BOLT_URI"
            data_dir="data-main"
            neo4j_home="/opt/neo4j-instance-main"
            ;;
        ycsb-backup)
            bolt_uri="$BACKUP_BOLT_URI"
            data_dir="data-backup"
            neo4j_home="/opt/neo4j-instance-backup"
            ;;
        ycsb-unchange)
            bolt_uri="$UNCHANGE_BOLT_URI"
            data_dir="data-unchange"
            neo4j_home="/opt/neo4j-instance-unchange"
            ;;
        *)
            echo "ERROR: Unknown DB role: $db_name" >&2
            return 1
            ;;
    esac

    initialize_database_instance "$bolt_uri" "$db_name" "$data_dir" "$neo4j_home"
}

initialize_database_instance() {
    local bolt_uri="$1"
    local instance_name="$2"
    local data_dir="$3"
    local neo4j_home="$4"

    echo "Initializing Neo4j instance '$instance_name' at $bolt_uri..."

    sudo -u neo4j "$neo4j_home/bin/neo4j" stop || true
    sudo -u neo4j rm -rf "$neo4j_home/$data_dir"/*

    # Seed auth
    sudo -u neo4j "$neo4j_home/bin/neo4j-admin" dbms set-initial-password "$DB_PWD"

    sudo -u neo4j "$neo4j_home/bin/neo4j" start

    echo "Waiting for Neo4j ($instance_name) to become ready..."
    for i in {1..30}; do
        if run_cypher "$bolt_uri" "RETURN 1;" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    create_table "$bolt_uri"

    echo "✅ Done initializing $instance_name."
}

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

log_query_plan() {
    local bolt_uri="$1"
    local phase_label="$2"
    local instance_label="$3"
    local ts
    local test_key
    local escaped_key
    local profile_output

    assert_bolt_uri "$bolt_uri" || return 1

    ts=$(date -Iseconds)
    test_key=$(run_cypher "$bolt_uri" \
        "MATCH (n:usertable) RETURN n.id AS id LIMIT 1;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')

    if [[ -n "$test_key" && "$test_key" != "NULL" ]]; then
        escaped_key=${test_key//\'/\\\'}
        profile_output=$(cypher-shell \
            -u "$DB_USERNAME" \
            -p "$DB_PWD" \
            -a "$bolt_uri" \
            --format verbose \
            "PROFILE MATCH (n:usertable {id: '$escaped_key'}) RETURN n LIMIT 1;" \
            2>/dev/null)
    else
        profile_output=$(cypher-shell \
            -u "$DB_USERNAME" \
            -p "$DB_PWD" \
            -a "$bolt_uri" \
            --format verbose \
            "PROFILE MATCH (n:usertable) RETURN n LIMIT 1;" \
            2>/dev/null)
    fi

    {
        echo "=== QUERY PLAN $ts | epoch=$epoch run=$run phase=$phase_label instance=$instance_label uri=$bolt_uri ==="
        echo "$profile_output"
        echo
    } >> "$QUERY_PLAN_LOG"
}

#----------------------------------------------------------#

######Main block of code######

# Initialize all three PHYSICAL databases
initialize_database "$MAIN_NAME"
initialize_database "$UNCHANGE_NAME"
initialize_database "$BACKUP_NAME"

# Clear the log file and previous backups
> $LOG_FILE
> $QUERY_PLAN_LOG
rm -rf $KEY_SIZE_LOG
# Clear the value size files to start fresh
> "$KEY_SIZE_FILE_AFTER_EXTEND"
> "$KEY_SIZE_FILE_AFTER_RUN"

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
readproportion=${readproportion:-""}
updateproportion=${updateproportion:-""}
scanproportion=${scanproportion:-""}
insertproportion=${insertproportion:-""}
extendproportion=${extendproportion:-""}

run_ycsb_load "$MAIN_NEO4J_URI"
measure_stats "$MAIN_BOLT_URI"
write_result "TRUE"

# Load unchange value size (reference) DB
run_ycsb_load "$UNCHANGE_NEO4J_URI"

# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

# Experiment parameters
for epoch in $(seq 1 1); do
    for run in $(seq 1 1); do
        
        # Setting parameter values for extend phase
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$extendoperationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"
        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0.2 and other proportions=0 ==="
        phase="extend"
        run_ycsb_run "$MAIN_NEO4J_URI" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$MAIN_BOLT_URI"
        write_result "FALSE"

        # Key Sizes
        echo "Size computation started"
        echo "ycsb_key,size" > "$KEY_SIZE_LOG"
        get_key_sizes_from_db "$MAIN_BOLT_URI" "$KEY_SIZE_LOG"
        get_key_sizes "$KEY_SIZE_LOG" "$HISTOGRAM_FILE"

        # Sanitize epoch and run for iteration calculation
        epoch_iter=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        run_iter=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        iteration=$((10 * (epoch_iter - 1) + run_iter))

        if [[ "$iteration" -eq 1 ]]; then
            # First iteration: (re)create file with header and initial data
            echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_EXTEND"
            append_first_iteration "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_EXTEND"
        else
            append_subsequent_iterations "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_EXTEND"
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
        perl -i -p -e "s/^operationcount=.*/operationcount=$original_operationcount/" $WORKLOAD_FILE
        grep -q '^fieldlengthdistribution=' "$WORKLOAD_FILE" || echo -e "\nfieldlengthdistribution=histogram" >> "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"
        # Extract workload parameters after sourcing
        recordcount=${recordcount:-""}
        readallfields=${readallfields:-""}
        requestdistribution=${requestdistribution:-""}
        readproportion=${readproportion:-""}
        updateproportion=${updateproportion:-""}
        scanproportion=${scanproportion:-""}
        insertproportion=${insertproportion:-""}
        extendproportion=${extendproportion:-""}

        # Save the existing keys in the database
        get_keys_from_db "$MAIN_BOLT_URI" "keys.txt"

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="run"
        log_query_plan "$MAIN_BOLT_URI" "$phase" "$MAIN_NAME"
        run_ycsb_run "$MAIN_NEO4J_URI" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$MAIN_BOLT_URI"
        write_result "FALSE"

        # Delete new keys that were inserted during the run
        get_keys_from_db "$MAIN_BOLT_URI" "keys_after_run.txt"
        delete_new_keys "$MAIN_BOLT_URI"

        # Workload with unchanging value sizes
        get_keys_from_db "$UNCHANGE_BOLT_URI" "keys.txt"
        phase="reference"
        run_ycsb_run "$UNCHANGE_NEO4J_URI" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$UNCHANGE_BOLT_URI"
        write_result "FALSE"

        # Delete new keys from unchange database
        get_keys_from_db "$UNCHANGE_BOLT_URI" "keys_after_run.txt"
        delete_new_keys "$UNCHANGE_BOLT_URI"
    
        # Sanitize epoch and run for condition check
        epoch_check=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        run_check=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        if (( $((10 * (epoch_check - 1) + run_check)) % 1 == 0 )); then
            phase="clean-run"
            
            echo "Backing up the database started"

            backup_instance \
            "/opt/neo4j-instance-main" "data-main" \
            "/opt/neo4j-instance-backup" "data-backup"

            echo "Waiting for backup Neo4j to become ready..."
            for i in {1..30}; do
                if run_cypher "$BACKUP_BOLT_URI" "RETURN 1;" >/dev/null 2>&1; then
                    break
                fi
                sleep 1
            done

            echo "Backing up the database finished"

            log_query_plan "$BACKUP_BOLT_URI" "$phase" "$BACKUP_NAME"
            run_ycsb_run "$BACKUP_NEO4J_URI" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
            measure_stats "$BACKUP_BOLT_URI"
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            echo "Size computation started"
            echo "ycsb_key,size" > "$KEY_SIZE_LOG"
            get_key_sizes_from_db "$BACKUP_BOLT_URI" "$KEY_SIZE_LOG"
            
            # Sanitize epoch and run for iteration calculation
            epoch_iter2=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
            run_iter2=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
            iteration=$((10 * (epoch_iter2 - 1) + run_iter2))

            if [[ "$iteration" -eq 1 ]]; then
                # First iteration: (re)create file with header and initial data
                echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_RUN"
                append_first_iteration "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_RUN"
            else
                append_subsequent_iterations "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            # Extract the recordcount from the workload file
            recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

            # PostgreSQL query to get the total size of all records
            total_size=$(get_total_size_from_db "$BACKUP_BOLT_URI")

            # Set average field length (with error handling)
            if [ -z "$total_size" ] || [ -z "$recordcount" ] || [ "$recordcount" -eq 0 ]; then
                log "[FIELDLEN]   Cannot calculate average field length"
                log "[FIELDLEN]   total_size=$total_size"
                log "[FIELDLEN]   recordcount=$recordcount"
                log "[FIELDLEN]   fallback=fieldlengthoriginal=$fieldlengthoriginal"

                fieldlengthaverage="$fieldlengthoriginal"
            else
                fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)

                log "[FIELDLEN] Computed average field length"
                log "[FIELDLEN]   total_size_bytes=$total_size"
                log "[FIELDLEN]   recordcount=$recordcount"
                log "[FIELDLEN]   fields_per_record=10"
                log "[FIELDLEN]   fieldlengthaverage=$fieldlengthaverage"
            fi

            # Change the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            initialize_database "$BACKUP_NAME"
            # Resetting the database with new data load
            log "=== Executing the load phase for the comparison study ==="
            run_ycsb_load "$BACKUP_NEO4J_URI"
            
            # Change the value size back for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthoriginal/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            # Execute the run phase
            log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
            phase="avg-run"
            log_query_plan "$BACKUP_BOLT_URI" "$phase" "$BACKUP_NAME"
            run_ycsb_run "$BACKUP_NEO4J_URI"
            measure_stats "$BACKUP_BOLT_URI"
            write_result "FALSE"
        fi
    done
done

# Delete intermediate temp files
# rm -rf $LOG_FILE
# rm -rf $OUTPUT_CSV
# rm -rf $KEY_SIZE_LOG

log "=== All steps completed. Results are logged in $LOG_FILE ==="
