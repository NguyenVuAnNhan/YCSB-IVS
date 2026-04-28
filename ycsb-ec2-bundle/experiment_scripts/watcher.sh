#!/usr/bin/env bash

# Required env vars:
# DB_PWD, DB_USERNAME, db_name, phase, epoch, metrics_file

# Optional: interval (seconds)
INTERVAL=${INTERVAL:-1}
DB_STATS_TABLE=${DB_STATS_TABLE:-usertable}

if [[ "$metrics_file" == *.metrics ]]; then
    default_db_stats_file="${metrics_file%.metrics}.dbstats"
else
    default_db_stats_file="${metrics_file}.dbstats"
fi
DB_STATS_FILE=${DB_STATS_FILE:-$default_db_stats_file}

null_csv() {
    local count="$1"
    local out="NULL"
    local i

    for ((i = 1; i < count; i++)); do
        out="$out,NULL"
    done

    printf '%s' "$out"
}

psql_csv() {
    local database="$1"
    local query="$2"

    PGPASSWORD="$DB_PWD" psql -X -q -t -A -F"," \
        -v ON_ERROR_STOP=1 \
        -v watch_db="$db_name" \
        -v stats_table="$DB_STATS_TABLE" \
        -U "$DB_USERNAME" \
        -d "$database" \
        -c "$query" 2>/dev/null | sed '/^[[:space:]]*$/d' | head -n 1
}

write_db_stats_header() {
    if [ -f "$DB_STATS_FILE" ]; then
        return
    fi

    mkdir -p "$(dirname "$DB_STATS_FILE")"
    {
        printf 'Phase,Epoch,Timestamp'
        printf ',numbackends,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes'
        printf ',checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time'
        printf ',wal_records,wal_fpi,wal_bytes,wal_buffers_full'
        printf ',heap_bytes,heap_total_bytes,toast_heap_bytes,toast_total_bytes,toast_index_bytes'
        printf ',n_live_tup,n_dead_tup,n_tup_ins,n_tup_upd,n_tup_hot_upd,vacuum_count,autovacuum_count\n'
    } > "$DB_STATS_FILE"
}

collect_db_stats() {
    local db_stats bgwriter_stats wal_stats relation_stats table_stats

    db_stats=$(psql_csv postgres "
        SELECT numbackends, blks_read, blks_hit, tup_returned, tup_fetched,
               tup_inserted, tup_updated, tup_deleted, deadlocks, temp_files,
               temp_bytes
        FROM pg_stat_database
        WHERE datname = :'watch_db';
    ")
    [ -z "$db_stats" ] && db_stats=$(null_csv 11)

    bgwriter_stats=$(psql_csv postgres "
        SELECT checkpoints_timed, checkpoints_req, buffers_checkpoint,
               buffers_clean, buffers_backend, buffers_alloc,
               checkpoint_write_time, checkpoint_sync_time
        FROM pg_stat_bgwriter;
    ")
    [ -z "$bgwriter_stats" ] && bgwriter_stats=$(null_csv 8)

    wal_stats=$(psql_csv postgres "
        SELECT wal_records, wal_fpi, wal_bytes, wal_buffers_full
        FROM pg_stat_wal;
    ")
    [ -z "$wal_stats" ] && wal_stats=$(null_csv 4)

    relation_stats=$(psql_csv "$db_name" "
        WITH heap AS (
            SELECT c.oid AS heap_oid,
                   c.reltoastrelid AS toast_oid
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = :'stats_table'
              AND c.relkind IN ('r', 'p')
            ORDER BY n.nspname = 'public' DESC, n.nspname, c.relname
            LIMIT 1
        ),
        rels AS (
            SELECT h.heap_oid,
                   h.toast_oid,
                   (
                       SELECT i.indexrelid
                       FROM pg_index i
                       WHERE i.indrelid = h.toast_oid
                       ORDER BY i.indexrelid
                       LIMIT 1
                   ) AS toast_index_oid
            FROM heap h
        )
        SELECT pg_relation_size(heap_oid),
               pg_total_relation_size(heap_oid),
               CASE WHEN toast_oid = 0 THEN 0 ELSE pg_relation_size(toast_oid) END,
               CASE WHEN toast_oid = 0 THEN 0 ELSE pg_total_relation_size(toast_oid) END,
               CASE WHEN toast_index_oid IS NULL THEN 0 ELSE pg_relation_size(toast_index_oid) END
        FROM rels;
    ")
    [ -z "$relation_stats" ] && relation_stats=$(null_csv 5)

    table_stats=$(psql_csv "$db_name" "
        SELECT n_live_tup, n_dead_tup, n_tup_ins, n_tup_upd, n_tup_hot_upd,
               vacuum_count, autovacuum_count
        FROM pg_stat_user_tables
        WHERE relname = :'stats_table'
        ORDER BY schemaname = 'public' DESC, schemaname, relname
        LIMIT 1;
    ")
    [ -z "$table_stats" ] && table_stats=$(null_csv 7)

    printf '%s,%s,%s,%s,%s' "$db_stats" "$bgwriter_stats" "$wal_stats" "$relation_stats" "$table_stats"
}

write_db_stats_header

if [ "${ONESHOT_DBSTATS:-0}" = "1" ]; then
    ts=$(date +%s)
    echo "$phase,$epoch,$ts,$(collect_db_stats)" >> "$DB_STATS_FILE"
    exit 0
fi

prev_read=0
prev_write=0

while true; do
    # --- Get PIDs ---
    pids=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d postgres -t -A \
        -v watch_db="$db_name" \
        -c "SELECT pid FROM pg_stat_activity WHERE datname = :'watch_db';" 2>/dev/null \
        | paste -sd "," -)

    if [ -z "$pids" ]; then
        cpu="NULL"
        mem_kb="NULL"
        delta_read="NULL"
        delta_write="NULL"
    else
        # --- CPU + Memory ---
        cpu=$(ps -p "$pids" -o %cpu= 2>/dev/null | awk '{sum += $1} END {print sum}')
        mem_kb=$(ps -p "$pids" -o rss= 2>/dev/null | awk '{sum += $1} END {print sum}')
        cpu=${cpu:-0}
        mem_kb=${mem_kb:-0}

        # --- Disk I/O (cumulative) ---
        read_bytes=0
        write_bytes=0

        IFS=',' read -ra pid_array <<< "$pids"
        for pid in "${pid_array[@]}"; do
            io_file="/proc/$pid/io"
            if [ -r "$io_file" ]; then
                r=$(awk '/read_bytes/ {print $2}' "$io_file")
                w=$(awk '/write_bytes/ {print $2}' "$io_file")
                read_bytes=$((read_bytes + r))
                write_bytes=$((write_bytes + w))
            fi
        done

        # --- Convert to per-interval (delta) ---
        delta_read=$((read_bytes - prev_read))
        delta_write=$((write_bytes - prev_write))

        # Handle PID churn / resets
        [ $delta_read -lt 0 ] && delta_read=0
        [ $delta_write -lt 0 ] && delta_write=0

        prev_read=$read_bytes
        prev_write=$write_bytes
    fi

    # --- Log ---
    ts=$(date +%s)
    echo "$phase,$epoch,$ts,$cpu,$mem_kb,$delta_read,$delta_write" >> "$metrics_file"
    echo "$phase,$epoch,$ts,$(collect_db_stats)" >> "$DB_STATS_FILE"

    sleep "$INTERVAL"
done
