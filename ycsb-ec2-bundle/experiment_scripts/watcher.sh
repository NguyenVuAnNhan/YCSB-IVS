#!/usr/bin/env bash

# Required env vars:
# DB_PWD, DB_USERNAME, db_name, phase, epoch, metrics_file
#
# metrics_file columns:
# Phase,Epoch,Timestamp,CPU,Memory,pg_delta_read_bytes,pg_delta_write_bytes

# Optional: interval (seconds)
INTERVAL=${INTERVAL:-5}
DB_STATS_INTERVAL=${DB_STATS_INTERVAL:-60}
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

    printf '%s\n' "$query" | PGPASSWORD="$DB_PWD" psql -X -q -t -A -F"," \
        -v ON_ERROR_STOP=1 \
        -v watch_db="$db_name" \
        -v stats_table="$DB_STATS_TABLE" \
        -U "$DB_USERNAME" \
        -d "$database" 2>/dev/null | sed '/^[[:space:]]*$/d' | head -n 1
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

collect_pg_io_totals() {
    local totals

    totals=$(psql_csv postgres "
        WITH settings AS (
            SELECT current_setting('block_size')::bigint AS block_size
        ),
        db AS (
            SELECT COALESCE(blks_read, 0)::bigint AS blks_read,
                   COALESCE(temp_bytes, 0)::bigint AS temp_bytes
            FROM pg_stat_database
            WHERE datname = :'watch_db'
        ),
        bgwriter AS (
            SELECT COALESCE(buffers_checkpoint, 0)::bigint AS buffers_checkpoint,
                   COALESCE(buffers_clean, 0)::bigint AS buffers_clean,
                   COALESCE(buffers_backend, 0)::bigint AS buffers_backend
            FROM pg_stat_bgwriter
        ),
        wal AS (
            SELECT COALESCE(wal_bytes, 0)::numeric::bigint AS wal_bytes
            FROM pg_stat_wal
        )
        SELECT (db.blks_read * settings.block_size)::bigint,
               (
                   wal.wal_bytes
                   + ((bgwriter.buffers_checkpoint + bgwriter.buffers_clean + bgwriter.buffers_backend) * settings.block_size)
                   + db.temp_bytes
               )::bigint
        FROM settings
        CROSS JOIN db
        CROSS JOIN bgwriter
        CROSS JOIN wal;
    ")

    if [ -z "$totals" ]; then
        totals=$(psql_csv postgres "
            WITH settings AS (
                SELECT current_setting('block_size')::bigint AS block_size
            ),
            db AS (
                SELECT COALESCE(blks_read, 0)::bigint AS blks_read,
                       COALESCE(temp_bytes, 0)::bigint AS temp_bytes
                FROM pg_stat_database
                WHERE datname = :'watch_db'
            ),
            bgwriter AS (
                SELECT COALESCE(buffers_checkpoint, 0)::bigint AS buffers_checkpoint,
                       COALESCE(buffers_clean, 0)::bigint AS buffers_clean,
                       COALESCE(buffers_backend, 0)::bigint AS buffers_backend
                FROM pg_stat_bgwriter
            )
            SELECT (db.blks_read * settings.block_size)::bigint,
                   (
                       ((bgwriter.buffers_checkpoint + bgwriter.buffers_clean + bgwriter.buffers_backend) * settings.block_size)
                       + db.temp_bytes
                   )::bigint
            FROM settings
            CROSS JOIN db
            CROSS JOIN bgwriter;
        ")
    fi

    printf '%s' "$totals"
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

write_db_stats_header

if [ "${ONESHOT_DBSTATS:-0}" = "1" ]; then
    ts=$(date +%s)
    echo "$phase,$epoch,$ts,$(collect_db_stats)" >> "$DB_STATS_FILE"
    exit 0
fi

prev_pg_read_bytes=""
prev_pg_write_bytes=""
last_db_stats=0

while true; do
    # --- Get PIDs ---
    pids=$(printf '%s\n' "SELECT pid FROM pg_stat_activity WHERE datname = :'watch_db';" \
        | PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d postgres -t -A \
        -v ON_ERROR_STOP=1 \
        -v watch_db="$db_name" 2>/dev/null \
        | paste -sd "," -)

    if [ -z "$pids" ]; then
        cpu="NULL"
        mem_kb="NULL"
    else
        # --- CPU + Memory ---
        cpu=$(ps -p "$pids" -o %cpu= 2>/dev/null | awk '{sum += $1} END {print sum}')
        mem_kb=$(ps -p "$pids" -o rss= 2>/dev/null | awk '{sum += $1} END {print sum}')
        cpu=${cpu:-0}
        mem_kb=${mem_kb:-0}
    fi

    pg_io_totals=$(collect_pg_io_totals)
    pg_read_bytes=${pg_io_totals%%,*}
    pg_write_bytes=${pg_io_totals#*,}

    if [ -z "$pg_io_totals" ] || [ "$pg_read_bytes" = "$pg_io_totals" ] \
        || ! is_integer "$pg_read_bytes" || ! is_integer "$pg_write_bytes"; then
        delta_read="NULL"
        delta_write="NULL"
    elif [ -z "$prev_pg_read_bytes" ] || [ -z "$prev_pg_write_bytes" ]; then
        delta_read=0
        delta_write=0
        prev_pg_read_bytes=$pg_read_bytes
        prev_pg_write_bytes=$pg_write_bytes
    else
        delta_read=$((pg_read_bytes - prev_pg_read_bytes))
        delta_write=$((pg_write_bytes - prev_pg_write_bytes))

        # PostgreSQL stats can reset; avoid negative deltas poisoning phase aggregates.
        [ "$delta_read" -lt 0 ] && delta_read=0
        [ "$delta_write" -lt 0 ] && delta_write=0

        prev_pg_read_bytes=$pg_read_bytes
        prev_pg_write_bytes=$pg_write_bytes
    fi

    # --- Log ---
    ts=$(date +%s)
    echo "$phase,$epoch,$ts,$cpu,$mem_kb,$delta_read,$delta_write" >> "$metrics_file"
    if [ "$DB_STATS_INTERVAL" -gt 0 ] && [ $((ts - last_db_stats)) -ge "$DB_STATS_INTERVAL" ]; then
        echo "$phase,$epoch,$ts,$(collect_db_stats)" >> "$DB_STATS_FILE"
        last_db_stats=$ts
    fi

    sleep "$INTERVAL"
done
