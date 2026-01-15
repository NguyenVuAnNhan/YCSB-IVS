#!/bin/bash

###### Neo4j-specific helpers and database functions ######

# Run a Cypher statement against a specific Neo4j database
run_cypher() {
    local db_name="$1"
    local query="$2"
    shift 2 || true
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$BOLT_URI" -d "$db_name" "$query" "$@"
}

# Drop a Neo4j database (multi-DB, via system database)
drop_database() {
    local db_name="${1:-$DB_NAME}"
    run_cypher "system" "DROP DATABASE $db_name IF EXISTS;" >/dev/null 2>&1 || true
}

# Create a Neo4j database (multi-DB, via system database)
create_database() {
    local db_name="${1:-$DB_NAME}"
    run_cypher "system" "CREATE DATABASE $db_name IF NOT EXISTS;" >/dev/null 2>&1 || true
}

# Create the main YCSB table/constraint in a given database
create_table() {
    local db_name="${1:-$DB_NAME}"
    # Unique constraint on id for :usertable
    run_cypher "$db_name" \
        "CREATE CONSTRAINT usertable_id IF NOT EXISTS FOR (n:usertable) REQUIRE n.id IS UNIQUE;" \
        >/dev/null 2>&1 || true
}

# Define database-specific binding field names (metrics collected from Neo4j)
# These should match the variable names set by collect_neo4j_metrics() function
binding_field_names=(
    "page_cache_hits"
    "page_cache_faults"
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
    "log_appended_bytes"
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
    local db_name="${1:-$DB_NAME}"

    # Defaults
    page_cache_hits="0"
    page_cache_faults="0"
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
    log_appended_bytes="0"
    transaction_started="0"
    transaction_terminated="0"

    # Page cache metrics
    page_cache_metrics=$(run_cypher "$db_name" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Page cache') YIELD attributes
         RETURN attributes['hits'].value AS hits, attributes['faults'].value AS faults;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    if [ -n "$page_cache_metrics" ]; then
        page_cache_hits=$(echo "$page_cache_metrics" | cut -d'|' -f1)
        page_cache_faults=$(echo "$page_cache_metrics" | cut -d'|' -f2)
    fi

    # Transaction metrics
    tx_metrics=$(run_cypher "$db_name" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Transactions') YIELD attributes
         RETURN attributes['NumberOfCommittedTransactions'].value AS commits,
                attributes['NumberOfRolledBackTransactions'].value AS rollbacks,
                attributes['PeakNumberOfConcurrentTransactions'].value AS peak_concurrent;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    if [ -n "$tx_metrics" ]; then
        transaction_commits=$(echo "$tx_metrics" | cut -d'|' -f1)
        transaction_rollbacks=$(echo "$tx_metrics" | cut -d'|' -f2)
        transaction_peak_concurrent=$(echo "$tx_metrics" | cut -d'|' -f3)
    fi

    # Current transaction count
    tx_active=$(run_cypher "$db_name" \
        "SHOW TRANSACTIONS YIELD transactionId RETURN count(*) AS count;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    transaction_active="${tx_active:-0}"

    # Primitive counts
    db_ops=$(run_cypher "$db_name" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Primitive count') YIELD attributes
         RETURN attributes['NumberOfNodeIdsInUse'].value AS nodes,
                attributes['NumberOfRelationshipIdsInUse'].value AS relationships,
                attributes['NumberOfPropertyIdsInUse'].value AS properties;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    if [ -n "$db_ops" ]; then
        nodes_created=$(echo "$db_ops" | cut -d'|' -f1)
        relationships_created=$(echo "$db_ops" | cut -d'|' -f2)
        properties_set=$(echo "$db_ops" | cut -d'|' -f3)
    fi

    # Checkpoint metrics
    checkpoint_metrics=$(run_cypher "$db_name" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Check pointing') YIELD attributes
         RETURN attributes['CheckPointTotalTime'].value AS total_time,
                attributes['NumberOfCheckPointEvents'].value AS events;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    if [ -n "$checkpoint_metrics" ]; then
        checkpoint_total_time=$(echo "$checkpoint_metrics" | cut -d'|' -f1)
        checkpoint_total_events=$(echo "$checkpoint_metrics" | cut -d'|' -f2)
    fi

    # Log rotation metrics
    log_metrics=$(run_cypher "$db_name" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Log rotation') YIELD attributes
         RETURN attributes['LogRotationEvents'].value AS events,
                attributes['LogRotationTotalTime'].value AS total_time;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    if [ -n "$log_metrics" ]; then
        log_rotation_events=$(echo "$log_metrics" | cut -d'|' -f1)
        log_rotation_total_time=$(echo "$log_metrics" | cut -d'|' -f2)
    fi

    # Store log file size (approximation for appended bytes)
    log_appended_bytes=$(run_cypher "$db_name" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Store file sizes') YIELD attributes
         RETURN attributes['LogFileSize'].value AS size;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    log_appended_bytes="${log_appended_bytes:-0}"
}

# Database-specific function to get key sizes (appends to file, caller should create header)
get_key_sizes_from_db() {
    local db_name="$1"
    local key_size_log="$2"

    run_cypher "$db_name" \
        "MATCH (n:usertable)
         RETURN n.id AS ycsb_key,
                reduce(total = 0, k IN ['field0','field1','field2','field3','field4','field5','field6','field7','field8','field9'] |
                    total + CASE WHEN n[k] IS NOT NULL THEN size(toString(n[k])) ELSE 0 END) AS size
         ORDER BY n.id;" \
        2>/dev/null | tail -n +2 | sed 's/|/,/' >> "$key_size_log"
}

# Database-specific function to get total size
get_total_size_from_db() {
    local db_name="$1"
    run_cypher "$db_name" \
        "MATCH (n:usertable)
         RETURN sum(reduce(total = 0, k IN ['field0','field1','field2','field3','field4','field5','field6','field7','field8','field9'] |
            total + CASE WHEN n[k] IS NOT NULL THEN size(toString(n[k])) ELSE 0 END)) AS total;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' '
}

# Database-specific function to get keys from database
get_keys_from_db() {
    local db_name="$1"
    local output_file="$2"
    run_cypher "$db_name" \
        "MATCH (n:usertable) RETURN n.id AS ycsb_key;" \
        2>/dev/null | tail -n +2 | sed 's/|//' > "$output_file"
}

# Database-specific function to delete keys
delete_batch_neo4j() {
  local db_name="$1"
  local batch_file="$2"

  # Convert batch file → JSON array ["k1","k2",...]
  keys_json=$(jq -R . < "$batch_file" | jq -s .)

  cypher-shell \
    -u "$DB_USERNAME" \
    -p "$DB_PWD" \
    -d "$db_name" \
    --fail-at-end \
    <<EOF
UNWIND $keys_json AS k
MATCH (n:usertable {id: k})
DETACH DELETE n;
EOF
}

# Database-specific function to backup database
backup_database() {
    local source_db="$1"
    local target_db="$2"
    local backup_dir="$3"

    mkdir -p "$backup_dir"

    log "Stopping Neo4j for backup..." 
    neo4j stop
    
    log "Dumping database '$source_db' to $backup_dir"
    neo4j-admin database dump "$source_db" \
    --to-path="$backup_dir"

    log "Loading dump into database '$target_db'"
    neo4j-admin database load "$target_db" \
    --from-path="$backup_dir" \
    --overwrite-destination=true

    log "Starting Neo4j after restore..." 
    neo4j start

    rm -rf "$backup_dir"
    log "Backup from '$source_db' to '$target_db' completed at $(date)"
}

# Database-specific function to truncate table
truncate_table() {
    local db_name="$1"
    neo4j-admin database drop "$db_name"
    neo4j-admin database create "$db_name"
}

measure_stats() {
    local db="${1:-$DB_NAME}"
    cpu=$(ps -u neo4j -o %cpu= | awk '{sum += $1} END {print sum}')
    memory=$(ps -u neo4j -o %mem= | awk '{sum += $1} END {print sum}')
    collect_neo4j_metrics "$db"
}

run_ycsb_load() {
    local db_url="${1:-$DB_URL}"
    $YCSB load neo4j -s -P $WORKLOAD_FILE \
        -p url="$db_url" -p username="$DB_USERNAME" -p password="$DB_PWD" > $OUTPUT_CSV 
}

run_ycsb_run() {
    local db_url="${1:-$DB_URL}"
    local extra_params="${2:-}"
    $YCSB run neo4j -s -P $WORKLOAD_FILE \
        -p url="$db_url" -p username="$DB_USERNAME" -p password="$DB_PWD" $extra_params > $OUTPUT_CSV
}

#----------------------------------------------------------#

######Constants######

YCSB="../bin/ycsb.sh"

# DB names (separate Neo4j databases)
DB_NAME="ycsb"
BACKUP_DB_NAME="ycsb_backup"
UNCHANGE_DB_NAME="ycsb_unchange"

# Neo4j connection URIs
BOLT_URI="bolt://localhost:7687"
NEO4J_URI_BASE="neo4j://localhost:7687"
DB_USERNAME="neo4j"
DB_PWD="password"

DB_URL="$NEO4J_URI_BASE?database=$DB_NAME"
BACKUP_URL="$NEO4J_URI_BASE?database=$BACKUP_DB_NAME"
BACKUP_DIR="./ycsb_neo4j_backup"
UNCHANGE_DB_URL="$NEO4J_URI_BASE?database=$UNCHANGE_DB_NAME"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_neo4j_results.log"
OUTPUT_CSV="../analysis/neo4j_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/neo4j_output.csv"
OUTPUT_FILE="../analysis/Data/Workload_data/neo4j_run1_uniform_light.csv"

# Key size gathering
KEY_SIZE_LOG="key_sizes.csv"
KEY_SIZE_FILE_AFTER_EXTEND="../analysis/Data/Value_size_data/value_sizes_neo4j_run1_uniform_light_before.csv"
KEY_SIZE_FILE_AFTER_RUN="../analysis/Data/Value_size_data/value_sizes_neo4j_run1_uniform_light_after.csv"
HISTOGRAM_FILE="histogram.txt"

# Extend phase experiment parameters
extendproportion_extend="1"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="0"
readmodifywriteproportion_extend="0"
requestdistribution_extend="zipfian"

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
    local db_name="$1"
    local keys_before_file="keys.txt"
    local keys_after_file="keys_after_run.txt"
    local keys_to_delete_file="keys_to_delete.txt"

    # Sort the key files
    sort "$keys_before_file" > keys_sorted.txt
    sort "$keys_after_file" > keys_after_sorted.txt

    # Find keys that are only in keys_after_run.txt
    comm -13 keys_sorted.txt keys_after_sorted.txt > "$keys_to_delete_file"

    echo "Deleting $(wc -l < "$keys_to_delete_file") new keys from database '$db_name'..."

    # Delete those keys
    BATCH_SIZE=1000
    if [ ! -s "$keys_to_delete_file" ]; then
        echo "No new keys to delete."
    else
        split -l "$BATCH_SIZE" "$keys_to_delete_file" keys_batch_
        for f in keys_batch_*; do
            echo "Deleting batch: $f"
            delete_batch_neo4j "$db_name" "$f"
        done
    fi

    if [ -s "$keys_to_delete_file" ]; then
        rm -f keys_batch_*
    fi

    rm -rf "$keys_after_file" "$keys_before_file" keys_sorted.txt keys_after_sorted.txt "$keys_to_delete_file"
    echo "✅ Deletion complete."
}

# Initialize database
initialize_database() {
    local db_name="$1"
    echo "Initializing database $db_name..."

    drop_database "$db_name"
    create_database "$db_name"
    create_table "$db_name"

    echo "Done initializing $db_name."
}

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

#----------------------------------------------------------#

######Main block of code######

# Initialize all three logical databases
initialize_database "$DB_NAME"
initialize_database "$UNCHANGE_DB_NAME"
initialize_database "$BACKUP_DB_NAME"

# Clear the log file and previous backups
> $LOG_FILE
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

run_ycsb_load "$DB_URL"
measure_stats "$DB_NAME"
write_result "TRUE"

# Load unchange value size (reference) DB
run_ycsb_load "$UNCHANGE_DB_URL"

# Save original operationcount before modifying it
original_operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

# Experiment parameters
for epoch in $(seq 1 3); do
    for run in $(seq 1 3); do
        
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
        run_ycsb_run "$DB_URL" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$DB_NAME"
        write_result "FALSE"

        # Key Sizes
        echo "Size computation started"
        echo "ycsb_key,size" > "$KEY_SIZE_LOG"
        get_key_sizes_from_db "$DB_NAME" "$KEY_SIZE_LOG"
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
        get_keys_from_db "$DB_NAME" "keys.txt"

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="run"
        run_ycsb_run "$DB_URL" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$DB_NAME"
        write_result "FALSE"

        # Delete new keys that were inserted during the run
        get_keys_from_db "$DB_NAME" "keys_after_run.txt"
        delete_new_keys "$DB_NAME"

        # Workload with unchanging value sizes
        get_keys_from_db "$UNCHANGE_DB_NAME" "keys.txt"
        phase="reference"
        run_ycsb_run "$UNCHANGE_DB_URL" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$UNCHANGE_DB_NAME"
        write_result "FALSE"

        # Delete new keys from unchange database
        get_keys_from_db "$UNCHANGE_DB_NAME" "keys_after_run.txt"
        delete_new_keys "$UNCHANGE_DB_NAME"
    
        # Sanitize epoch and run for condition check
        epoch_check=$(echo "$epoch" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        run_check=$(echo "$run" | head -1 | tr -d '\n\r ' | grep -o '^[0-9]*' || echo "0")
        if (( $((10 * (epoch_check - 1) + run_check)) % 1 == 0 )); then
            phase="clean-run"
            
            echo "Backing up the database started"
            backup_database "$DB_NAME" "$BACKUP_DB_NAME" "$BACKUP_DIR"
            echo "Backing up the database finished"

            run_ycsb_run "$BACKUP_URL" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
            measure_stats "$BACKUP_DB_NAME"
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            echo "Size computation started"
            echo "ycsb_key,size" > "$KEY_SIZE_LOG"
            get_key_sizes_from_db "$BACKUP_DB_NAME" "$KEY_SIZE_LOG"
            
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
            total_size=$(get_total_size_from_db "$BACKUP_DB_NAME")

            # Set average field length (with error handling)
            if [ -z "$total_size" ] || [ -z "$recordcount" ] || [ "$recordcount" -eq 0 ]; then
                echo "Warning: Cannot calculate fieldlengthaverage - total_size=$total_size, recordcount=$recordcount"
                fieldlengthaverage="$fieldlengthoriginal"
            else
                fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)
            fi

            echo "$total_size" "$fieldlengthaverage"

            # Change the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            truncate_table "$BACKUP_DB_NAME"

            # Resetting the database with new data load
            log "=== Executing the load phase for the comparison study ==="
            run_ycsb_load "$BACKUP_URL"
            
            # Change the value size back for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthoriginal/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            # Execute the run phase
            log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
            phase="avg-run"
            run_ycsb_run "$BACKUP_URL"
            measure_stats "$BACKUP_DB_NAME"
            write_result "FALSE"
        fi
    done
done

# Delete intermediate temp files
# rm -rf $LOG_FILE
# rm -rf $OUTPUT_CSV
# rm -rf $KEY_SIZE_LOG

log "=== All steps completed. Results are logged in $LOG_FILE ==="
