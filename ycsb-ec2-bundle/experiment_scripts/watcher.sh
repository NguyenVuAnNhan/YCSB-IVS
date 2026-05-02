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
PG_1S_FILE=${PG_1S_FILE:-}
OS_1S_FILE=${OS_1S_FILE:-}

prev_disk_ts_ms=""
prev_disk_reads=""
prev_disk_writes=""
prev_disk_read_sectors=""
prev_disk_write_sectors=""
prev_disk_io_ms=""
prev_disk_weighted_io_ms=""

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

write_pg_1s_header() {
    if [ -z "$PG_1S_FILE" ] || [ -f "$PG_1S_FILE" ]; then
        return
    fi

    mkdir -p "$(dirname "$PG_1S_FILE")"
    {
        printf 'DBName,Phase,Epoch,TimestampUnixMs'
        printf ',numbackends,blks_read,blks_hit,tup_returned,tup_fetched,tup_inserted,tup_updated,tup_deleted,deadlocks,temp_files,temp_bytes'
        printf ',checkpoints_timed,checkpoints_req,buffers_checkpoint,buffers_clean,buffers_backend,buffers_alloc,checkpoint_write_time,checkpoint_sync_time'
        printf ',wal_records,wal_fpi,wal_bytes,wal_buffers_full'
        printf ',heap_bytes,heap_total_bytes,toast_heap_bytes,toast_total_bytes,toast_index_bytes'
        printf ',n_live_tup,n_dead_tup,n_tup_ins,n_tup_upd,n_tup_hot_upd,vacuum_count,autovacuum_count'
        printf ',active_backends,idle_backends,wait_client_count,wait_io_count,wait_lock_count,wait_lwlock_count,wait_timeout_count,wait_activity_count,wait_bufferpin_count,wait_extension_count\n'
    } > "$PG_1S_FILE"
}

write_os_1s_header() {
    if [ -z "$OS_1S_FILE" ] || [ -f "$OS_1S_FILE" ]; then
        return
    fi

    mkdir -p "$(dirname "$OS_1S_FILE")"
    {
        printf 'DBName,Phase,Epoch,TimestampUnixMs'
        printf ',postgres_cpu_pct,postgres_rss_kb,mem_available_kb,mem_dirty_kb,mem_writeback_kb'
        printf ',disk_reads_s,disk_writes_s,disk_read_kb_s,disk_write_kb_s,disk_await_ms,disk_aqu_sz,disk_util_pct\n'
    } > "$OS_1S_FILE"
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

collect_wait_stats() {
    local wait_stats

    wait_stats=$(psql_csv postgres "
        SELECT
          count(*) FILTER (WHERE state = 'active') AS active_backends,
          count(*) FILTER (WHERE state = 'idle') AS idle_backends,
          count(*) FILTER (WHERE wait_event_type = 'Client') AS wait_client_count,
          count(*) FILTER (WHERE wait_event_type = 'IO') AS wait_io_count,
          count(*) FILTER (WHERE wait_event_type = 'Lock') AS wait_lock_count,
          count(*) FILTER (WHERE wait_event_type = 'LWLock') AS wait_lwlock_count,
          count(*) FILTER (WHERE wait_event_type = 'Timeout') AS wait_timeout_count,
          count(*) FILTER (WHERE wait_event_type = 'Activity') AS wait_activity_count,
          count(*) FILTER (WHERE wait_event_type = 'BufferPin') AS wait_bufferpin_count,
          count(*) FILTER (WHERE wait_event_type = 'Extension') AS wait_extension_count
        FROM pg_stat_activity
        WHERE datname = :'watch_db';
    ")
    [ -z "$wait_stats" ] && wait_stats=$(null_csv 10)
    printf '%s' "$wait_stats"
}

collect_meminfo() {
    awk '
        /^MemAvailable:/ {avail=$2}
        /^Dirty:/ {dirty=$2}
        /^Writeback:/ {writeback=$2}
        END {
            printf "%s,%s,%s", avail + 0, dirty + 0, writeback + 0
        }
    ' /proc/meminfo
}

collect_disk_totals() {
    awk '
        $3 ~ /^(loop|ram|fd|sr)/ {next}
        {
            reads += $4
            read_sectors += $6
            writes += $8
            write_sectors += $10
            io_ms += $13
            weighted_io_ms += $14
        }
        END {
            printf "%d,%d,%d,%d,%d,%d", reads, writes, read_sectors, write_sectors, io_ms, weighted_io_ms
        }
    ' /proc/diskstats
}

collect_disk_rates() {
    local now_ms totals reads writes read_sectors write_sectors io_ms weighted_io_ms
    local elapsed_ms delta_reads delta_writes delta_read_sectors delta_write_sectors delta_io_ms delta_weighted_io_ms

    now_ms=$(date +%s%3N)
    totals=$(collect_disk_totals)
    IFS=, read -r reads writes read_sectors write_sectors io_ms weighted_io_ms <<< "$totals"

    if [ -z "$prev_disk_ts_ms" ]; then
        prev_disk_ts_ms="$now_ms"
        prev_disk_reads="$reads"
        prev_disk_writes="$writes"
        prev_disk_read_sectors="$read_sectors"
        prev_disk_write_sectors="$write_sectors"
        prev_disk_io_ms="$io_ms"
        prev_disk_weighted_io_ms="$weighted_io_ms"
        printf '0,0,0,0,0,0,0'
        return
    fi

    elapsed_ms=$((now_ms - prev_disk_ts_ms))
    [ "$elapsed_ms" -le 0 ] && elapsed_ms=1
    delta_reads=$((reads - prev_disk_reads))
    delta_writes=$((writes - prev_disk_writes))
    delta_read_sectors=$((read_sectors - prev_disk_read_sectors))
    delta_write_sectors=$((write_sectors - prev_disk_write_sectors))
    delta_io_ms=$((io_ms - prev_disk_io_ms))
    delta_weighted_io_ms=$((weighted_io_ms - prev_disk_weighted_io_ms))

    [ "$delta_reads" -lt 0 ] && delta_reads=0
    [ "$delta_writes" -lt 0 ] && delta_writes=0
    [ "$delta_read_sectors" -lt 0 ] && delta_read_sectors=0
    [ "$delta_write_sectors" -lt 0 ] && delta_write_sectors=0
    [ "$delta_io_ms" -lt 0 ] && delta_io_ms=0
    [ "$delta_weighted_io_ms" -lt 0 ] && delta_weighted_io_ms=0

    awk -v elapsed_ms="$elapsed_ms" \
        -v dr="$delta_reads" \
        -v dw="$delta_writes" \
        -v drs="$delta_read_sectors" \
        -v dws="$delta_write_sectors" \
        -v dio="$delta_io_ms" \
        -v dwio="$delta_weighted_io_ms" '
        BEGIN {
            elapsed_s = elapsed_ms / 1000.0
            ops = dr + dw
            reads_s = dr / elapsed_s
            writes_s = dw / elapsed_s
            read_kb_s = (drs * 512.0 / 1024.0) / elapsed_s
            write_kb_s = (dws * 512.0 / 1024.0) / elapsed_s
            await_ms = (ops > 0) ? dio / ops : 0
            aqu_sz = dwio / elapsed_ms
            util_pct = dio * 100.0 / elapsed_ms
            if (util_pct > 100) util_pct = 100
            printf "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f", reads_s, writes_s, read_kb_s, write_kb_s, await_ms, aqu_sz, util_pct
        }'

    prev_disk_ts_ms="$now_ms"
    prev_disk_reads="$reads"
    prev_disk_writes="$writes"
    prev_disk_read_sectors="$read_sectors"
    prev_disk_write_sectors="$write_sectors"
    prev_disk_io_ms="$io_ms"
    prev_disk_weighted_io_ms="$weighted_io_ms"
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
write_pg_1s_header
write_os_1s_header

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
    ts_ms=$(date +%s%3N)
    echo "$phase,$epoch,$ts,$cpu,$mem_kb,$delta_read,$delta_write" >> "$metrics_file"
    if [ -n "$PG_1S_FILE" ]; then
        echo "$db_name,$phase,$epoch,$ts_ms,$(collect_db_stats),$(collect_wait_stats)" >> "$PG_1S_FILE"
    fi
    if [ -n "$OS_1S_FILE" ]; then
        echo "$db_name,$phase,$epoch,$ts_ms,$cpu,$mem_kb,$(collect_meminfo),$(collect_disk_rates)" >> "$OS_1S_FILE"
    fi
    if [ "$DB_STATS_INTERVAL" -gt 0 ] && [ $((ts - last_db_stats)) -ge "$DB_STATS_INTERVAL" ]; then
        echo "$phase,$epoch,$ts,$(collect_db_stats)" >> "$DB_STATS_FILE"
        last_db_stats=$ts
    fi

    sleep "$INTERVAL"
done
