#!/bin/bash

######Change database functions to work with a new database here######

drop_database() {
    local db_url="${1:-$DB_URL}"
    # Neo4j: Delete all nodes with the usertable label
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" "MATCH (n:usertable) DETACH DELETE n;" 2>/dev/null || true
}

create_database() {
    local db_url="${1:-$DB_URL}"
    # Verify connection
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" "RETURN 1;" > /dev/null 2>&1 || echo "Warning: Could not connect to Neo4j"
}

create_table() {
    local db_url="${1:-$DB_URL}"
    # Verify we can run a query
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" "RETURN 1;" > /dev/null 2>&1 || true
}

# Define database-specific binding field names (metrics collected from the database)
# These should match the variable names set by collect_metrics() function
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

# Function to extract Neo4j database statistics (Neo4j 5.x)
collect_neo4j_metrics() {
    local db_url="${1:-$DB_URL}"
    
    # Neo4j 5.x metrics collection using latest procedures
    # Using dbms.queryJmx for comprehensive metrics
    
    # Get page cache metrics
    page_cache_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Page cache') YIELD attributes
         RETURN attributes['hits'].value AS hits, attributes['faults'].value AS faults;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$page_cache_metrics" ]; then
        page_cache_hits=$(echo "$page_cache_metrics" | cut -d'|' -f1)
        page_cache_faults=$(echo "$page_cache_metrics" | cut -d'|' -f2)
    else
        page_cache_hits="0"
        page_cache_faults="0"
    fi
    
    # Get transaction metrics
    tx_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Transactions') YIELD attributes
         RETURN attributes['NumberOfCommittedTransactions'].value AS commits,
                attributes['NumberOfRolledBackTransactions'].value AS rollbacks,
                attributes['PeakNumberOfConcurrentTransactions'].value AS peak_concurrent;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$tx_metrics" ]; then
        transaction_commits=$(echo "$tx_metrics" | cut -d'|' -f1)
        transaction_rollbacks=$(echo "$tx_metrics" | cut -d'|' -f2)
        transaction_peak_concurrent=$(echo "$tx_metrics" | cut -d'|' -f3)
    else
        transaction_commits="0"
        transaction_rollbacks="0"
        transaction_peak_concurrent="0"
    fi
    
    # Get current transaction count
    tx_active=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "SHOW TRANSACTIONS YIELD transactionId RETURN count(*) AS count;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    transaction_active="${tx_active:-0}"
    
    # Get database operations metrics
    db_ops=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Primitive count') YIELD attributes
         RETURN attributes['NumberOfNodeIdsInUse'].value AS nodes,
                attributes['NumberOfRelationshipIdsInUse'].value AS relationships,
                attributes['NumberOfPropertyIdsInUse'].value AS properties;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$db_ops" ]; then
        nodes_created=$(echo "$db_ops" | cut -d'|' -f1)
        relationships_created=$(echo "$db_ops" | cut -d'|' -f2)
        properties_set=$(echo "$db_ops" | cut -d'|' -f3)
    else
        nodes_created="0"
        relationships_created="0"
        properties_set="0"
    fi
    
    # Get index metrics
    index_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Index sampling') YIELD attributes
         RETURN attributes['IndexSamplingJobCount'].value AS sampling_count;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    # Try to get index hits/misses from index statistics
    index_stats=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "SHOW INDEXES YIELD name, state, type, populationPercent;" \
        2>/dev/null | wc -l)
    index_hits="0"
    index_misses="0"
    
    # Get lock metrics
    lock_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Locking') YIELD attributes
         RETURN attributes['NumberOfLockedEntities'].value AS locked;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    lock_acquisition_time="0"
    lock_wait_time="0"
    
    # Get checkpoint metrics
    checkpoint_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Check pointing') YIELD attributes
         RETURN attributes['CheckPointTotalTime'].value AS total_time,
                attributes['NumberOfCheckPointEvents'].value AS events;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$checkpoint_metrics" ]; then
        checkpoint_total_time=$(echo "$checkpoint_metrics" | cut -d'|' -f1)
        checkpoint_total_events=$(echo "$checkpoint_metrics" | cut -d'|' -f2)
    else
        checkpoint_total_time="0"
        checkpoint_total_events="0"
    fi
    
    # Get log rotation metrics
    log_metrics=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Log rotation') YIELD attributes
         RETURN attributes['LogRotationEvents'].value AS events,
                attributes['LogRotationTotalTime'].value AS total_time;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    
    if [ -n "$log_metrics" ]; then
        log_rotation_events=$(echo "$log_metrics" | cut -d'|' -f1)
        log_rotation_total_time=$(echo "$log_metrics" | cut -d'|' -f2)
    else
        log_rotation_events="0"
        log_rotation_total_time="0"
    fi
    
    # Get log appended bytes
    log_appended_bytes=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "CALL dbms.queryJmx('org.neo4j:instance=kernel#0,name=Store file sizes') YIELD attributes
         RETURN attributes['LogFileSize'].value AS size;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    log_appended_bytes="${log_appended_bytes:-0}"
    
    # Set defaults for metrics that might not be available
    nodes_deleted="0"
    relationships_deleted="0"
    transaction_started="0"
    transaction_terminated="0"
}

# Database-specific function to get key sizes
get_key_sizes_from_db() {
    local db_url="$1"
    local key_size_log="$2"
    
    echo "ycsb_key,size" > "$key_size_log"
    # Neo4j: Calculate size as sum of all property values for each node
    # Properties are stored as field0, field1, ..., field9
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "MATCH (n:usertable)
         RETURN n.id AS ycsb_key,
                reduce(total = 0, key IN ['field0','field1','field2','field3','field4','field5','field6','field7','field8','field9'] | 
                    total + CASE WHEN n[key] IS NOT NULL THEN size(toString(n[key])) ELSE 0 END) AS size
         ORDER BY n.id;" \
        2>/dev/null | tail -n +2 | sed 's/|/,/' >> "$key_size_log" || true
}

# Database-specific function to get total size
get_total_size_from_db() {
    local db_url="$1"
    # Neo4j: Calculate total size of all properties (field0-field9)
    total_size=$(cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "MATCH (n:usertable)
         RETURN sum(reduce(total = 0, key IN ['field0','field1','field2','field3','field4','field5','field6','field7','field8','field9'] | 
            total + CASE WHEN n[key] IS NOT NULL THEN size(toString(n[key])) ELSE 0 END)) AS total;" \
        2>/dev/null | tail -n +2 | head -1 | tr -d ' ')
    echo "${total_size:-0}"
}

# Database-specific function to get keys from database
get_keys_from_db() {
    local db_url="$1"
    local output_file="$2"
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "MATCH (n:usertable) RETURN n.id AS ycsb_key ORDER BY n.id;" \
        2>/dev/null | tail -n +2 | sed 's/|//' > "$output_file" || true
}

# Database-specific function to delete keys
delete_keys_from_db() {
    local db_url="$1"
    local keys_file="$2"
    while read key; do
        [ -n "$key" ] && cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
            "MATCH (n:usertable {id: '$key'}) DETACH DELETE n;" 2>/dev/null || true
    done < "$keys_file"
}

# Database-specific function to backup database
backup_database() {
    local source_url="$1"
    local target_url="$2"
    local backup_file="$3"
    
    # This is a simplified backup
    echo "Creating Neo4j backup..."
    
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$source_url" \
        "MATCH (n:usertable)
         RETURN n.id AS id, 
                n.field0 AS field0, n.field1 AS field1, n.field2 AS field2,
                n.field3 AS field3, n.field4 AS field4, n.field5 AS field5,
                n.field6 AS field6, n.field7 AS field7, n.field8 AS field8,
                n.field9 AS field9;" \
        2>/dev/null > "$backup_file" || true
}

# Database-specific function to truncate (clear all data)
truncate_table() {
    local db_url="$1"
    cypher-shell -u "$DB_USERNAME" -p "$DB_PWD" -a "$db_url" \
        "MATCH (n:usertable) DETACH DELETE n;" 2>/dev/null || true
}

measure_stats() {
    local db_url="${1:-$DB_URL}"
    cpu=$(ps -u neo4j -o %cpu= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
    memory=$(ps -u neo4j -o %mem= 2>/dev/null | awk '{sum += $1} END {print sum+0}' || echo "0")
    collect_neo4j_metrics "$db_url"
}

run_ycsb_load() {
    local db_url="${1:-$DB_URL}"
    $YCSB load neo4j -s -P $WORKLOAD_FILE -p url="$db_url" -p username="$DB_USERNAME" -p password="$DB_PWD" > $OUTPUT_CSV 
}

run_ycsb_run() {
    local db_url="${1:-$DB_URL}"
    local extra_params="${2:-}"
    $YCSB run neo4j -s -P $WORKLOAD_FILE -p url="$db_url" -p username="$DB_USERNAME" -p password="$DB_PWD" $extra_params > $OUTPUT_CSV
}

#----------------------------------------------------------#

######Constants######

YCSB="../bin/ycsb.sh"

# DB names (Neo4j uses a single database, but we can use different labels or instances)
DB_NAME="ycsb"
BACKUP_DB_NAME="ycsb_backup"
UNCHANGE_DB_NAME="ycsb_unchange"

# Path to the Neo4j database
# Neo4j connection URL format: bolt://host:port or neo4j://host:port
DB_URL="bolt://localhost:7687"
DB_USERNAME="neo4j"
DB_PWD="password"
BACKUP_URL="bolt://localhost:7687"
BACKUP_FILE="./ycsb_dump.cypher"
UNCHANGE_DB_URL="bolt://localhost:7687"

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
    | awk '{ORS=","; print}'
}

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Remove rows not starting with specific operations and filter specific operations
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    if [ "$first" == "TRUE" ]; then   
        # Extract unique second values (except the first one) and create header
        dynamic_fields_header=$(extract_dynamic_fields "$filtered_output")
        header="$common_header,$stats_header,$prop_header,$runtime_header,$dynamic_fields_header"
        echo "$header" > "$OUTPUT_FILE"
    fi

    # Iterate through each line
    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
    # Set default values for epoch and run if not set (e.g., during load phase)
    epoch=${epoch:-0}
    run=${run:-0}
    recordcount=${recordcount:-$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)}
    readallfields=${readallfields:-$(grep -E '^readallfields=' "$WORKLOAD_FILE" | cut -d'=' -f2)}
    requestdistribution=${requestdistribution:-$(grep -E '^requestdistribution=' "$WORKLOAD_FILE" | cut -d'=' -f2)}
    readproportion=${readproportion:-$(grep -E '^readproportion=' "$WORKLOAD_FILE" | cut -d'=' -f2)}
    updateproportion=${updateproportion:-$(grep -E '^updateproportion=' "$WORKLOAD_FILE" | cut -d'=' -f2)}
    scanproportion=${scanproportion:-$(grep -E '^scanproportion=' "$WORKLOAD_FILE" | cut -d'=' -f2)}
    insertproportion=${insertproportion:-$(grep -E '^insertproportion=' "$WORKLOAD_FILE" | cut -d'=' -f2)}
    extendproportion=${extendproportion:-$(grep -E '^extendproportion=' "$WORKLOAD_FILE" | cut -d'=' -f2)}
    
    while IFS= read -r line; do
        # Extract operation and third value
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')
        r=$((10 * ($epoch - 1) + $run))

        run_specific=()
        # Extract throughput
        while IFS= read -r inner_line; do
            # Extract third value
            tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
            run_specific+=("$tmp")
        done <<< "$overall_output"

        # Populate field arrays dynamically
        common_fields=(
            "$r"
            "$phase"
            "$recordcount"
            "$readallfields"
            "$requestdistribution"
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

        dynamic_fields=("${run_specific[@]}" "$third_value")

        # Append to the values variable
        if [ $k -eq 1 ]; then
            row_fields=(
                "${common_fields[@]}"
                "${binding_fields[@]}"
                "${prop_fields[@]}"
                "${dynamic_fields[@]}"
            )

            # join with commas
            IFS=',' values_1="${row_fields[*]}"

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

            # join with commas
            IFS=',' values_2="${row_fields[*]}"

            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    # Print the values to the output file
    echo "$values_1" >> "$OUTPUT_FILE"
    echo "$values_2" >> "$OUTPUT_FILE"

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
    local db_url="$1"
    local keys_before_file="keys.txt"
    local keys_after_file="keys_after_run.txt"
    local keys_to_delete_file="keys_to_delete.txt"

    # Sort the key files
    sort "$keys_before_file" > keys_sorted.txt
    sort "$keys_after_file" > keys_after_sorted.txt

    # Find keys that are only in keys_after_run.txt
    comm -13 keys_sorted.txt keys_after_sorted.txt > "$keys_to_delete_file"

    echo "Deleting $(wc -l < "$keys_to_delete_file") new keys from database..."

    # Delete those keys
    if [ -s "$keys_to_delete_file" ]; then
        delete_keys_from_db "$db_url" "$keys_to_delete_file"
    fi

    rm -rf "$keys_after_file" "$keys_before_file" keys_sorted.txt keys_after_sorted.txt "$keys_to_delete_file"
    echo "Deletion complete."
}

# Initialize database
initialize_database() {
    local db_url="${1:-$DB_URL}"
    echo "Initializing Neo4j database..."

    drop_database "$db_url"
    create_database "$db_url"
    create_table "$db_url"

    echo "Done initializing."
}

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

#----------------------------------------------------------#

######Main block of code######

initialize_database "$DB_URL"
initialize_database "$UNCHANGE_DB_URL"

# Clear the log file and previous backups
> $LOG_FILE
rm -rf $BACKUP_DIR
rm -rf $KEY_SIZE_FILE

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
run_ycsb_load "$DB_URL"
measure_stats "$DB_URL"
write_result "TRUE"

# Load unchange value size (reference) DB
run_ycsb_load "$UNCHANGE_DB_URL"

# Experiment parameters
for epoch in $(seq 1 10); do
    for run in $(seq 1 10); do

        # Record operation count from workload configuration file
        opscount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        
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

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=1 and other proportions=0 ==="
        phase="extend"
        run_ycsb_run "$DB_URL" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$DB_URL"
        write_result "FALSE"

        # Key Sizes
        echo "Size computation started"
        get_key_sizes_from_db "$DB_URL" "$KEY_SIZE_LOG"
        get_key_sizes "$KEY_SIZE_LOG" "$HISTOGRAM_FILE"

        # Check if the output file exists, if not, create it with headers
        iteration=$((10*($epoch-1)+$run))

        if [[ ! -f "$KEY_SIZE_FILE_AFTER_EXTEND" ]]; then
            # Add header row (Key, Run1, Run2, ...)
            echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_EXTEND"
        fi

        # If it's the first iteration, append keys and sizes for the first run
        if [[ "$iteration" -eq 1 ]]; then
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
        perl -i -p -e "s/^operationcount=.*/operationcount=$opscount/" $WORKLOAD_FILE
        grep -q '^fieldlengthdistribution=' "$WORKLOAD_FILE" || echo -e "\nfieldlengthdistribution=histogram" >> "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        # Save the existing keys in the database
        get_keys_from_db "$DB_URL" "keys.txt"

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and readproportion=1 ==="
        phase="run"
        run_ycsb_run "$DB_URL" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$DB_URL"
        write_result "FALSE"

        # Delete new keys that were inserted during the run
        get_keys_from_db "$DB_URL" "keys_after_run.txt"
        delete_new_keys "$DB_URL"

        # Workload with unchanging value sizes
        get_keys_from_db "$UNCHANGE_DB_URL" "keys.txt"
        phase="reference"
        run_ycsb_run "$UNCHANGE_DB_URL" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
        measure_stats "$UNCHANGE_DB_URL"
        write_result "FALSE"

        # Delete new keys from unchange database
        get_keys_from_db "$UNCHANGE_DB_URL" "keys_after_run.txt"
        delete_new_keys "$UNCHANGE_DB_URL"
    
        if (( $((10*($epoch-1)+$run)) % 1 == 0 )); then
            phase="clean-run"
            
            echo "Backing up the database started"
            backup_database "$DB_URL" "$BACKUP_URL" "$BACKUP_FILE"
            echo "Backing up the database finished"

            run_ycsb_run "$BACKUP_URL" "-p fieldlengthhistogram=$HISTOGRAM_FILE"
            measure_stats "$BACKUP_URL"
            rm -rf "$BACKUP_FILE"
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            echo "Size computation started"
            get_key_sizes_from_db "$BACKUP_URL" "$KEY_SIZE_LOG"
            
            # Check if the output file exists, if not, create it with headers
            iteration=$((10*($epoch-1)+$run))
            if [[ ! -f "$KEY_SIZE_FILE_AFTER_RUN" ]]; then
                # Add header row (Key, Run1, Run2, ...)
                echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            # If it's the first iteration, append keys and sizes for the first run
            if [[ "$iteration" -eq 1 ]]; then
                append_first_iteration "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_RUN"
            else
                append_subsequent_iterations "$KEY_SIZE_LOG" "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            # Extract the recordcount from the workload file
            recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

            # Get total size and calculate average field length
            total_size=$(get_total_size_from_db "$BACKUP_URL")
            fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)

            echo "$total_size" "$fieldlengthaverage"

            # Change the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            truncate_table "$BACKUP_URL"

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
            measure_stats "$BACKUP_URL"
            write_result "FALSE"
        fi
    done
done

# Delete intermediate temp files
# rm -rf $LOG_FILE
# rm -rf $OUTPUT_CSV
# rm -rf $KEY_SIZE_LOG

log "=== All steps completed. Results are logged in $LOG_FILE ==="
