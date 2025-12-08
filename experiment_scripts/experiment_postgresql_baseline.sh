#!/bin/bash

YCSB="bin/ycsb.sh"

# DB names
DB_NAME="ycsb"
BACKUP_DB_NAME="ycsb_backup"
UNCHANGE_DB_NAME="ycsb_unchange"

# Path to the PostgreSQL data directory
DB_URL="jdbc:postgresql://localhost:5432/$DB_NAME"
JDBC_PROPERTIES="jdbc-binding/conf/postgres.properties"
DB_USERNAME="ycsb"
DB_PWD="USyd2025"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_postgresql_results.log"
OUTPUT_CSV="../analysis/postgresql_output.csv"

# Define input and output filenames  
INPUT_FILE="../analysis/postgresql_output.csv"
OUTPUT_FILE="../analysis/Data/Baseline_data/postgresql_run1_spreadrun_light.csv"

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
readproportion_postextend="0.5"
updateproportion_postextend="0.5"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="10000"

# Initialize PostgreSQL database
initialize_database() {
    echo "Initializing PostgreSQL database $DB_NAME..."

    sudo -u postgres dropdb --if-exists "$DB_NAME"
    sudo -u postgres createdb "$DB_NAME"

    # create table
    sudo -u postgres psql -d "$DB_NAME" -c \
        "CREATE TABLE usertable (
            ycsb_key TEXT PRIMARY KEY,
            field0 TEXT, field1 TEXT, field2 TEXT, field3 TEXT, field4 TEXT,
            field5 TEXT, field6 TEXT, field7 TEXT, field8 TEXT, field9 TEXT
        );"

    # grant table privileges to YCSB user
    sudo -u postgres psql -d "$DB_NAME" -c \
        "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USERNAME;"

    echo "Done initializing."
}

initialize_database

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

# Clear the log file
> $LOG_FILE

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Remove rows not starting with specific operations and filter specific operations
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    if [ "$first" == "TRUE" ]; then   
        # Extract unique second values (except the first one) and create header
        header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,btree_height,adaptive_hash_hash_searches,adaptive_hash_non_hash_searches,background_log_sync,buffer_pool_dump_status,buffer_pool_load_status,buffer_pool_resize_status,buffer_pool_load_incomplete,buffer_pool_pages_data,buffer_pool_bytes_data,buffer_pool_pages_dirty,buffer_pool_bytes_dirty,buffer_pool_pages_flushed,buffer_pool_pages_free,buffer_pool_pages_made_not_young,buffer_pool_pages_made_young,buffer_pool_pages_misc,buffer_pool_pages_old,buffer_pool_pages_total,buffer_pool_pages_lru_flushed,buffer_pool_pages_lru_freed,buffer_pool_pages_split,buffer_pool_read_ahead_rnd,buffer_pool_read_ahead,buffer_pool_read_ahead_evicted,buffer_pool_read_requests,buffer_pool_reads,buffer_pool_wait_free,buffer_pool_write_requests,checkpoint_age,checkpoint_max_age,data_fsyncs,data_pending_fsyncs,data_pending_reads,data_pending_writes,data_read,data_reads,data_writes,data_written,dblwr_pages_written,dblwr_writes,deadlocks,history_list_length,ibuf_discarded_delete_marks,ibuf_discarded_deletes,ibuf_discarded_inserts,ibuf_free_list,ibuf_merged_delete_marks,ibuf_merged_deletes,ibuf_merged_inserts,ibuf_merges,ibuf_segment_size,ibuf_size,log_waits,log_write_requests,log_writes,lsn_current,lsn_flushed,lsn_last_checkpoint,master_thread_active_loops,master_thread_idle_loops,max_trx_id,mem_adaptive_hash,mem_dictionary,os_log_written,page_size,pages_created,pages_read,pages_written,row_lock_current_waits,row_lock_time,row_lock_time_avg,row_lock_time_max,row_lock_waits,num_open_files,truncated_status_writes,available_undo_logs,undo_truncations,page_compression_saved,num_pages_page_compressed,num_page_compressed_trim_op,num_pages_page_decompressed,num_pages_page_compression_error,num_pages_encrypted,num_pages_decrypted,have_lz4,have_lzo,have_lzma,have_bzip2,have_snappy,have_punch_hole,defragment_compression_failures,defragment_failures,defragment_count,instant_alter_column,onlineddl_rowlog_rows,onlineddl_rowlog_pct_used,onlineddl_pct_progress,encryption_rotation_pages_read_from_cache,encryption_rotation_pages_read_from_disk,encryption_rotation_pages_modified,encryption_rotation_pages_flushed,encryption_rotation_estimated_iops,encryption_n_merge_blocks_encrypted,encryption_n_merge_blocks_decrypted,encryption_n_rowlog_blocks_encrypted,encryption_n_rowlog_blocks_decrypted,encryption_n_temp_blocks_encrypted,encryption_n_temp_blocks_decrypted,encryption_num_key_requests,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec),$(awk '{print $2}' <<< "$filtered_output" | sed 's/,$//' | uniq | awk '{ORS=","; print}')"
        echo "$header" > "$OUTPUT_FILE"
    fi

    # Iterate through each line
    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
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

        # Append to the values variable
        if [ $k -eq 1 ]; then
            values_1="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$btree_height,$adaptive_hash_hash_searches,$adaptive_hash_non_hash_searches,$background_log_sync,$buffer_pool_dump_status,$buffer_pool_load_status,$buffer_pool_resize_status,$buffer_pool_load_incomplete,$buffer_pool_pages_data,$buffer_pool_bytes_data,$buffer_pool_pages_dirty,$buffer_pool_bytes_dirty,$buffer_pool_pages_flushed,$buffer_pool_pages_free,$buffer_pool_pages_made_not_young,$buffer_pool_pages_made_young,$buffer_pool_pages_misc,$buffer_pool_pages_old,$buffer_pool_pages_total,$buffer_pool_pages_lru_flushed,$buffer_pool_pages_lru_freed,$buffer_pool_pages_split,$buffer_pool_read_ahead_rnd,$buffer_pool_read_ahead,$buffer_pool_read_ahead_evicted,$buffer_pool_read_requests,$buffer_pool_reads,$buffer_pool_wait_free,$buffer_pool_write_requests,$checkpoint_age,$checkpoint_max_age,$data_fsyncs,$data_pending_fsyncs,$data_pending_reads,$data_pending_writes,$data_read,$data_reads,$data_writes,$data_written,$dblwr_pages_written,$dblwr_writes,$deadlocks,$history_list_length,$ibuf_discarded_delete_marks,$ibuf_discarded_deletes,$ibuf_discarded_inserts,$ibuf_free_list,$ibuf_merged_delete_marks,$ibuf_merged_deletes,$ibuf_merged_inserts,$ibuf_merges,$ibuf_segment_size,$ibuf_size,$log_waits,$log_write_requests,$log_writes,$lsn_current,$lsn_flushed,$lsn_last_checkpoint,$master_thread_active_loops,$master_thread_idle_loops,$max_trx_id,$mem_adaptive_hash,$mem_dictionary,$os_log_written,$page_size,$pages_created,$pages_read,$pages_written,$row_lock_current_waits,$row_lock_time,$row_lock_time_avg,$row_lock_time_max,$row_lock_waits,$num_open_files,$truncated_status_writes,$available_undo_logs,$undo_truncations,$page_compression_saved,$num_pages_page_compressed,$num_page_compressed_trim_op,$num_pages_page_decompressed,$num_pages_page_compression_error,$num_pages_encrypted,$num_pages_decrypted,$have_lz4,$have_lzo,$have_lzma,$have_bzip2,$have_snappy,$have_punch_hole,$defragment_compression_failures,$defragment_failures,$defragment_count,$instant_alter_column,$onlineddl_rowlog_rows,$onlineddl_rowlog_pct_used,$onlineddl_pct_progress,$encryption_rotation_pages_read_from_cache,$encryption_rotation_pages_read_from_disk,$encryption_rotation_pages_modified,$encryption_rotation_pages_flushed,$encryption_rotation_estimated_iops,$encryption_n_merge_blocks_encrypted,$encryption_n_merge_blocks_decrypted,$encryption_n_rowlog_blocks_encrypted,$encryption_n_rowlog_blocks_decrypted,$encryption_n_temp_blocks_encrypted,$encryption_n_temp_blocks_decrypted,$encryption_num_key_requests,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"            
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            values_2="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$btree_height,$adaptive_hash_hash_searches,$adaptive_hash_non_hash_searches,$background_log_sync,$buffer_pool_dump_status,$buffer_pool_load_status,$buffer_pool_resize_status,$buffer_pool_load_incomplete,$buffer_pool_pages_data,$buffer_pool_bytes_data,$buffer_pool_pages_dirty,$buffer_pool_bytes_dirty,$buffer_pool_pages_flushed,$buffer_pool_pages_free,$buffer_pool_pages_made_not_young,$buffer_pool_pages_made_young,$buffer_pool_pages_misc,$buffer_pool_pages_old,$buffer_pool_pages_total,$buffer_pool_pages_lru_flushed,$buffer_pool_pages_lru_freed,$buffer_pool_pages_split,$buffer_pool_read_ahead_rnd,$buffer_pool_read_ahead,$buffer_pool_read_ahead_evicted,$buffer_pool_read_requests,$buffer_pool_reads,$buffer_pool_wait_free,$buffer_pool_write_requests,$checkpoint_age,$checkpoint_max_age,$data_fsyncs,$data_pending_fsyncs,$data_pending_reads,$data_pending_writes,$data_read,$data_reads,$data_writes,$data_written,$dblwr_pages_written,$dblwr_writes,$deadlocks,$history_list_length,$ibuf_discarded_delete_marks,$ibuf_discarded_deletes,$ibuf_discarded_inserts,$ibuf_free_list,$ibuf_merged_delete_marks,$ibuf_merged_deletes,$ibuf_merged_inserts,$ibuf_merges,$ibuf_segment_size,$ibuf_size,$log_waits,$log_write_requests,$log_writes,$lsn_current,$lsn_flushed,$lsn_last_checkpoint,$master_thread_active_loops,$master_thread_idle_loops,$max_trx_id,$mem_adaptive_hash,$mem_dictionary,$os_log_written,$page_size,$pages_created,$pages_read,$pages_written,$row_lock_current_waits,$row_lock_time,$row_lock_time_avg,$row_lock_time_max,$row_lock_waits,$num_open_files,$truncated_status_writes,$available_undo_logs,$undo_truncations,$page_compression_saved,$num_pages_page_compressed,$num_page_compressed_trim_op,$num_pages_page_decompressed,$num_pages_page_compression_error,$num_pages_encrypted,$num_pages_decrypted,$have_lz4,$have_lzo,$have_lzma,$have_bzip2,$have_snappy,$have_punch_hole,$defragment_compression_failures,$defragment_failures,$defragment_count,$instant_alter_column,$onlineddl_rowlog_rows,$onlineddl_rowlog_pct_used,$onlineddl_pct_progress,$encryption_rotation_pages_read_from_cache,$encryption_rotation_pages_read_from_disk,$encryption_rotation_pages_modified,$encryption_rotation_pages_flushed,$encryption_rotation_estimated_iops,$encryption_n_merge_blocks_encrypted,$encryption_n_merge_blocks_decrypted,$encryption_n_rowlog_blocks_encrypted,$encryption_n_rowlog_blocks_decrypted,$encryption_n_temp_blocks_encrypted,$encryption_n_temp_blocks_decrypted,$encryption_num_key_requests,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
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

# Function to close the RocksDB database
close_db() {
    local db_path="$1"
    log "=== Closing RocksDB database at $db_path ==="
    DB=$(basename $db_path)
    if [ -d "$db_path" ]; then
        lsof | grep "$db_path" | awk '{print $2}' | xargs kill -9
        log "Closed RocksDB database at $db_path"
    else
        log "No RocksDB database found at $db_path"
    fi
}

# Function to extract PostgreSQL database and background writer statistics
collect_postgres_metrics() {
    local db="$DB_NAME"

    # database-level stats
    read blks_read blks_hit tup_returned tup_fetched tup_inserted tup_updated tup_deleted deadlocks temp_files temp_bytes <<< \
        $(sudo -u postgres psql -d "$db" -Xt -c "
            SELECT blks_read, blks_hit, tup_returned, tup_fetched,
                   tup_inserted, tup_updated, tup_deleted, deadlocks,
                   temp_files, temp_bytes
            FROM pg_stat_database
            WHERE datname = '$db';
        ")

    # bgwriter (checkpoints etc.)
    read checkpoints_timed checkpoints_req buffers_checkpoint buffers_clean buffers_backend buffers_alloc checkpoint_write_time checkpoint_sync_time <<< \
        $(sudo -u postgres psql -d "$db" -Xt -c "
            SELECT checkpoints_timed, checkpoints_req,
                   buffers_checkpoint, buffers_clean,
                   buffers_backend, buffers_alloc,
                   checkpoint_write_time, checkpoint_sync_time
            FROM pg_stat_bgwriter;
        ")

    # wal metrics if available
    if sudo -u postgres psql -d "$db" -c "\d pg_stat_wal" &>/dev/null; then
        read wal_bytes wal_records wal_fpi wal_buffers_full <<< \
            $(sudo -u postgres psql -d "$db" -Xt -c "
                SELECT wal_bytes, wal_records, wal_fpi, wal_buffers_full
                FROM pg_stat_wal;
            ")
    else
        wal_bytes=""; wal_records=""; wal_fpi=""; wal_buffers_full=""
    fi
}

# Step 1: Delete the ycsb database on MongoDB if any
log "=== Deleting the ycsb database on MongoDB, if any ==="
#rm -rf "$DB_PATH"
#echo "RocksDB database at $DB_PATH has been deleted."

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
$YCSB load jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV 
#sstsize=$(du -sck "$DB_PATH"/*.sst | tail -n 1| cut -f1)
#logsize=$(du -sck "$DB_PATH"/*.log | tail -n 1| cut -f1)
cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*") 
extract_innodb_stats $DB_NAME
write_result "TRUE"

# Experiment parameters
for epoch in $(seq 1 10); do
    for run in $(seq 1 10); do

        # Set proportions for insert mode
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

        # Extract the recordcount and operationcount from the workload file
        operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        
        # Compute the new record number to be added
        updatedoperationcount=$(echo "($extendoperationcount / 10)" | bc)

        # Change operation count for insert mode
        perl -i -p -e "s/^operationcount=.*/operationcount=$updatedoperationcount/" $WORKLOAD_FILE

        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"

        # Compute new record count
        updatedrecordcount=$(echo "$recordcount + ($extendoperationcount / 10)" | bc)

        # Setting parameter values for read phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^recordcount=.*/recordcount=$updatedrecordcount/" $WORKLOAD_FILE
        # Change operation count for read mode
        perl -i -p -e "s/^operationcount=.*/operationcount=$operationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE" 

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="spread-run"
        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV
        cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
        memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*")
        extract_innodb_stats $DB_NAME
        write_result "FALSE"

    done
done

# Delete intermediate temp files
rm -rf $LOG_FILE
rm -rf $OUTPUT_CSV

log "=== All steps completed. Results are logged in $LOG_FILE ==="
