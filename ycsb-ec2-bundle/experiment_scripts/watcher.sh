#!/usr/bin/env bash

# Required env vars:
# DB_PWD, DB_USERNAME, db_name, phase, epoch, metrics_file

# Optional: interval (seconds)
INTERVAL=${INTERVAL:-1}

prev_read=0
prev_write=0

while true; do
    # --- Get PIDs ---
    pids=$(PGPASSWORD="$DB_PWD" psql -U "$DB_USERNAME" -d postgres -t -A -c \
        "SELECT pid FROM pg_stat_activity WHERE datname = '$db_name';" \
        | paste -sd "," -)

    echo "PIDs: $pids"

    if [ -z "$pids" ]; then
        cpu="NULL"
        mem_kb="NULL"
        delta_read="NULL"
        delta_write="NULL"
    else
        # --- CPU + Memory ---
        cpu=$(ps -p "$pids" -o %cpu= 2>/dev/null | awk '{sum += $1} END {print sum}')
        mem_kb=$(ps -p "$pids" -o rss= 2>/dev/null | awk '{sum += $1} END {print sum}')

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

    sleep "$INTERVAL"
done