#!/bin/bash
# media-mirror.sh — Perpetual media conversion and transfer pipeline
# Converts a source media library to a target resolution and mirrors to a remote host.
# SOURCE FILES ARE READ-ONLY — NEVER MODIFIED.
set -euo pipefail

export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Build ffmpeg flags from config
FFMPEG_VIDEO="-c:v libx264 -crf ${FFMPEG_CRF:-23} -preset ${FFMPEG_PRESET:-medium} -vf scale=-2:${TARGET_HEIGHT:-720}"
FFMPEG_AUDIO="-c:a aac -b:a 128k -ac 2"
FFMPEG_EXTRA="-movflags +faststart -map 0:v:0 -map 0:a:0"

# Parse flags
RUN_ONCE=false
if [[ "${1:-}" == "--once" ]]; then
    RUN_ONCE=true
fi

# Ensure directories exist
mkdir -p "$TEMP_DIR" "$LOG_DIR"

# ─── State management ────────────────────────────────────────────────

init_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"jobs":[],"stats":{"total_files":0,"converted":0,"transferred":0,"failed":0,"skipped":0},"runner":{"status":"idle","started":"","paused":false}}' | python3 -m json.tool > "$STATE_FILE"
    fi
}

update_runner() {
    local status="$1"
    python3 -c "
import json, datetime
with open('$STATE_FILE','r') as f: state=json.load(f)
state['runner']['status']='$status'
if '$status'=='running': state['runner']['started']=datetime.datetime.now().isoformat()
with open('$STATE_FILE','w') as f: json.dump(state,f)
"
}

is_paused() {
    python3 -c "
import json
with open('$STATE_FILE','r') as f: state=json.load(f)
exit(0 if state['runner'].get('paused',False) else 1)
" 2>/dev/null
}

update_job() {
    local file_path="$1"
    local media_type="$2"
    local status="$3"
    local progress="${4:-0}"
    local detail="${5:-}"
    python3 << PYEOF
import json, datetime
with open('$STATE_FILE','r') as f: state=json.load(f)
job = None
for j in state['jobs']:
    if j['source'] == '''$file_path''':
        job = j
        break
if job is None:
    job = {'source': '''$file_path''', 'media_type': '$media_type', 'status': 'queued', 'progress': 0, 'detail': '', 'started': '', 'updated': ''}
    state['jobs'].append(job)
job['status'] = '$status'
job['progress'] = $progress
job['detail'] = '''$detail'''
job['updated'] = datetime.datetime.now().isoformat()
if '$status' == 'converting' and not job.get('started'):
    job['started'] = datetime.datetime.now().isoformat()
stats = state['stats']
stats['total_files'] = len(state['jobs'])
stats['converted'] = len([j for j in state['jobs'] if j['status'] in ('transferred','done')])
stats['transferred'] = len([j for j in state['jobs'] if j['status'] == 'done'])
stats['failed'] = len([j for j in state['jobs'] if j['status'] == 'failed'])
stats['skipped'] = len([j for j in state['jobs'] if j['status'] == 'skipped'])
with open('$STATE_FILE','w') as f: json.dump(state,f)
PYEOF
}

# ─── Helpers ──────────────────────────────────────────────────────────

get_relative_path() {
    local full_path="$1"
    local source_root="$2"
    echo "${full_path#$source_root/}"
}

is_already_done() {
    local file_path="$1"
    python3 -c "
import json
with open('$STATE_FILE','r') as f: state=json.load(f)
for j in state['jobs']:
    if j['source'] == '''$file_path''' and j['status'] in ('done','skipped'):
        exit(0)
exit(1)
" 2>/dev/null
}

dest_exists() {
    local rel_path="$1"
    local dest_base="$2"
    local out_name="${rel_path%.*}.${OUTPUT_EXT}"
    ssh -i "$DEST_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$INSTALL_DIR/known_hosts" \
        "$DEST_HOST" "test -f \"${dest_base}/${out_name}\"" 2>/dev/null
}

# ─── Convert ──────────────────────────────────────────────────────────

convert_file() {
    local source_file="$1"
    local media_type="$2"
    local source_root="$3"
    local rel_path
    rel_path=$(get_relative_path "$source_file" "$source_root")
    local out_name="${rel_path%.*}.${OUTPUT_EXT}"
    local temp_out="$TEMP_DIR/$out_name"
    local log_file="$LOG_DIR/convert_$(echo "$rel_path" | tr '/' '_' | tr ' ' '_').log"

    mkdir -p "$(dirname "$temp_out")"

    local dest_base
    if [ "$media_type" = "movies" ]; then dest_base="$DEST_MOVIES"; else dest_base="$DEST_TV"; fi

    if dest_exists "$rel_path" "$dest_base"; then
        update_job "$source_file" "$media_type" "skipped" 100 "Already on destination"
        return 0
    fi

    if [ -f "$temp_out" ]; then
        update_job "$source_file" "$media_type" "transferring" 50 "Using existing temp file"
        transfer_file "$temp_out" "$rel_path" "$media_type" "$source_file"
        return $?
    fi

    # Check source resolution — skip encoding if already <= target
    local src_height
    src_height=$(ffmpeg -i "$source_file" 2>&1 | grep "Video:" | head -1 | grep -oE "[0-9]+x[0-9]+" | head -1 | cut -d"x" -f2)

    if [ -n "$src_height" ] && [ "$src_height" -le "${TARGET_HEIGHT:-720}" ] 2>/dev/null; then
        update_job "$source_file" "$media_type" "converting" 50 "Already ${src_height}p — copying without re-encode"
        cp "$source_file" "$temp_out"
        update_job "$source_file" "$media_type" "transferring" 50 "Copy complete, starting transfer"
        transfer_file "$temp_out" "$rel_path" "$media_type" "$source_file"
        return $?
    fi

    update_job "$source_file" "$media_type" "converting" 0 "Starting ${src_height:-?}p → ${TARGET_HEIGHT:-720}p conversion"

    local duration
    duration=$(ffmpeg -i "$source_file" 2>&1 | grep "Duration" | head -1 | sed 's/.*Duration: \([^,]*\).*/\1/' | awk -F: '{print ($1*3600)+($2*60)+$3}')
    [ -z "$duration" ] || [ "$duration" = "0" ] && duration=1

    ffmpeg -hide_banner -nostdin -y \
        -i "$source_file" \
        $FFMPEG_VIDEO $FFMPEG_AUDIO $FFMPEG_EXTRA \
        -progress pipe:1 \
        "$temp_out" > "$log_file.progress" 2>"$log_file" &

    local ffmpeg_pid=$!
    local pct=0

    while kill -0 "$ffmpeg_pid" 2>/dev/null; do
        while is_paused; do
            kill -STOP "$ffmpeg_pid" 2>/dev/null || true
            update_job "$source_file" "$media_type" "converting" "$pct" "PAUSED"
            sleep 5
        done
        kill -CONT "$ffmpeg_pid" 2>/dev/null || true

        if [ -f "$log_file.progress" ]; then
            local out_time
            out_time=$(grep "out_time_us=" "$log_file.progress" 2>/dev/null | tail -1 | sed 's/out_time_us=//')
            if [ -n "$out_time" ] && [ "$out_time" != "N/A" ]; then
                local out_secs=$((out_time / 1000000))
                pct=$((out_secs * 100 / ${duration%.*}))
                [ "$pct" -gt 100 ] && pct=100
                local speed
                speed=$(grep "speed=" "$log_file.progress" 2>/dev/null | tail -1 | sed 's/speed=//')
                update_job "$source_file" "$media_type" "converting" "$pct" "Speed: ${speed:-?} | ${pct}%"
            fi
        fi
        sleep 3
    done

    wait "$ffmpeg_pid"
    local exit_code=$?
    rm -f "$log_file.progress"

    if [ $exit_code -ne 0 ]; then
        update_job "$source_file" "$media_type" "failed" 0 "Conversion failed (exit $exit_code)"
        rm -f "$temp_out"
        return 1
    fi

    if [ ! -s "$temp_out" ]; then
        update_job "$source_file" "$media_type" "failed" 0 "Output file empty or missing"
        rm -f "$temp_out"
        return 1
    fi

    update_job "$source_file" "$media_type" "transferring" 50 "Conversion complete, starting transfer"
    transfer_file "$temp_out" "$rel_path" "$media_type" "$source_file"
}

# ─── Transfer ─────────────────────────────────────────────────────────

transfer_file() {
    local local_file="$1"
    local rel_path="$2"
    local media_type="$3"
    local source_file="$4"
    local out_name="${rel_path%.*}.${OUTPUT_EXT}"

    local dest_base
    if [ "$media_type" = "movies" ]; then dest_base="$DEST_MOVIES"; else dest_base="$DEST_TV"; fi

    local dest_path="${dest_base}/${out_name}"
    local dest_dir
    dest_dir=$(dirname "$dest_path")
    local log_file="$LOG_DIR/transfer_$(echo "$rel_path" | tr '/' '_' | tr ' ' '_').log"

    ssh -i "$DEST_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$INSTALL_DIR/known_hosts" \
        "$DEST_HOST" "mkdir -p \"$dest_dir\""

    rsync -avz --partial --progress \
        --bwlimit="$RSYNC_BWLIMIT" \
        -e "ssh -i $DEST_SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=$INSTALL_DIR/known_hosts" \
        "$local_file" \
        "${DEST_HOST}:\"${dest_path}\"" > "$log_file" 2>&1 &

    local rsync_pid=$!

    while kill -0 "$rsync_pid" 2>/dev/null; do
        while is_paused; do
            kill -STOP "$rsync_pid" 2>/dev/null || true
            update_job "$source_file" "$media_type" "transferring" 75 "PAUSED"
            sleep 5
        done
        kill -CONT "$rsync_pid" 2>/dev/null || true

        if [ -f "$log_file" ]; then
            local xfer_info
            xfer_info=$(grep -o '[0-9]*%' "$log_file" 2>/dev/null | tail -1)
            local speed_info
            speed_info=$(grep -oE '[0-9.]+[KMG]B/s' "$log_file" 2>/dev/null | tail -1)
            update_job "$source_file" "$media_type" "transferring" 75 "Transfer: ${xfer_info:-0%} @ ${speed_info:-?}"
        fi
        sleep 3
    done

    wait "$rsync_pid"
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        update_job "$source_file" "$media_type" "failed" 50 "Transfer failed (exit $exit_code)"
        return 1
    fi

    rm -f "$local_file"
    update_job "$source_file" "$media_type" "done" 100 "Complete"
    return 0
}

# ─── Scan ─────────────────────────────────────────────────────────────

scan_and_process() {
    local source_root="$1"
    local media_type="$2"

    echo "[$(date)] Scanning $media_type: $source_root"

    find "$source_root" -type f \( \
        -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" \
        -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.wmv" \
        -o -iname "*.ts" -o -iname "*.flv" -o -iname "*.webm" \
    \) | sort | while IFS= read -r file; do
        if is_already_done "$file"; then
            continue
        fi
        echo "[$(date)] Processing: $file"
        convert_file "$file" "$media_type" "$source_root" || {
            echo "[$(date)] FAILED: $file"
        }
    done
}

# ─── Main ─────────────────────────────────────────────────────────────

echo "=========================================="
echo " Media Mirror — Perpetual Conversion Pipeline"
echo "=========================================="
echo "Source Movies:  $SOURCE_MOVIES"
echo "Source TV:      $SOURCE_TV"
echo "Temp Dir:       $TEMP_DIR"
echo "Dest Movies:    $DEST_HOST:$DEST_MOVIES"
echo "Dest TV:        $DEST_HOST:$DEST_TV"
echo "Resolution:     ${TARGET_HEIGHT:-720}p | CRF: ${FFMPEG_CRF:-23} | Preset: ${FFMPEG_PRESET:-medium}"
echo "Bandwidth:      ${RSYNC_BWLIMIT} KB/s"
echo "Dashboard:      http://$(hostname):$DASHBOARD_PORT"
echo "=========================================="

init_state
echo $$ > "$PID_FILE"

cleanup() {
    echo "[$(date)] Shutting down..."
    update_runner "stopped"
    rm -f "$PID_FILE"
    exit 0
}
trap cleanup SIGINT SIGTERM

update_runner "running"

if [ "$RUN_ONCE" = true ]; then
    scan_and_process "$SOURCE_MOVIES" "movies"
    scan_and_process "$SOURCE_TV" "tv"
    update_runner "idle"
    echo "[$(date)] Single scan complete."
    exit 0
fi

while true; do
    scan_and_process "$SOURCE_MOVIES" "movies"
    scan_and_process "$SOURCE_TV" "tv"

    # Check if there are still unprocessed files (initial bulk sync)
    PENDING=$(python3 -c "
import json
s=json.load(open('$STATE_FILE'))
done_count=len([j for j in s['jobs'] if j['status'] in ('done','skipped')])
total=s['stats'].get('total_files',0)
# If we processed new files this cycle and there are likely more source files, skip sleep
print('bulk' if done_count < total * 0.95 else 'idle')
" 2>/dev/null || echo "idle")

    if [ "$PENDING" = "bulk" ]; then
        echo "[$(date)] Bulk sync in progress — continuing immediately..."
        sleep 5  # Brief pause to avoid hammering
    else
        echo "[$(date)] Scan complete. Sleeping ${SCAN_INTERVAL}s before next scan..."
        update_runner "idle"
        sleep "$SCAN_INTERVAL"
    fi
    update_runner "running"
done
