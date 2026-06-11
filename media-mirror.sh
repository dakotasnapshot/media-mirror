#!/bin/bash
# media-mirror.sh — Perpetual media conversion and transfer pipeline
# Converts a source media library to a target resolution and mirrors to a remote host.
# SOURCE FILES ARE READ-ONLY — NEVER MODIFIED.
set -euo pipefail

export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Build ffmpeg flags from config. The video filter is built per-file so the
# effective height can adapt down as the destination fills (see below).
FFMPEG_AUDIO="-c:a aac -b:a 128k -ac 2"
FFMPEG_EXTRA="-movflags +faststart -map 0:v:0 -map 0:a:0"

build_video_flags() {
    local height="$1"
    echo "-c:v libx264 -crf ${FFMPEG_CRF:-23} -preset ${FFMPEG_PRESET:-medium} -threads ${FFMPEG_THREADS:-4} -vf scale=-2:${height}"
}

# Adaptive-resolution defaults (config may override)
ADAPTIVE_RESOLUTION="${ADAPTIVE_RESOLUTION:-1}"
RESOLUTION_LADDER="${RESOLUTION_LADDER:-1080 720 480 360 240}"
MIN_DEST_FREE_GB="${MIN_DEST_FREE_GB:-20}"

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

# ─── Adaptive resolution ──────────────────────────────────────────────
# As the destination drive fills, step the encode height DOWN through
# RESOLUTION_LADDER so the remaining library still fits. The current effective
# height lives in state.json so it is sticky across files and visible in the UI.

dest_free_gb() {
    # Free whole-GB on the destination mount for the given path. Echoes a large
    # number on failure so a transient SSH hiccup never triggers a needless
    # downstep.
    local dest_path="$1"
    local kb
    kb=$(ssh -i "$DEST_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -o UserKnownHostsFile="$INSTALL_DIR/known_hosts" \
            "$DEST_HOST" "df -k '$dest_path' 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null || true)
    if [ -n "$kb" ] && [[ "$kb" =~ ^[0-9]+$ ]]; then
        echo $(( kb / 1024 / 1024 ))
    else
        echo 999999
    fi
}

get_effective_height() {
    python3 -c "
import json
try:
    s=json.load(open('$STATE_FILE'))
    print(s.get('runner',{}).get('effective_height') or ${TARGET_HEIGHT:-720})
except Exception:
    print(${TARGET_HEIGHT:-720})
" 2>/dev/null || echo "${TARGET_HEIGHT:-720}"
}

set_effective_height() {
    local height="$1"
    python3 -c "
import json
s=json.load(open('$STATE_FILE'))
s.setdefault('runner',{})['effective_height']=int($height)
s['runner']['target_height']=int(${TARGET_HEIGHT:-720})
json.dump(s,open('$STATE_FILE','w'))
" 2>/dev/null || true
}

# Echo the next rung at or below the given height; if none lower exists, echo
# the same height. Only rungs <= TARGET_HEIGHT are considered.
ladder_below() {
    local current="$1"
    local target="${TARGET_HEIGHT:-720}"
    local best=""
    for rung in $RESOLUTION_LADDER; do
        # eligible rungs are strictly below current AND <= configured target
        if [ "$rung" -lt "$current" ] && [ "$rung" -le "$target" ]; then
            if [ -z "$best" ] || [ "$rung" -gt "$best" ]; then
                best="$rung"
            fi
        fi
    done
    if [ -n "$best" ]; then echo "$best"; else echo "$current"; fi
}

# If adaptive mode is on and the destination is below the free-space floor,
# drop to the next-lower ladder rung. Returns the (possibly new) effective height.
maybe_downstep() {
    local dest_base="$1"
    local effective
    effective=$(get_effective_height)
    if [ "${ADAPTIVE_RESOLUTION:-1}" != "1" ]; then
        echo "$effective"; return 0
    fi
    local free_gb
    free_gb=$(dest_free_gb "$dest_base")
    if [ "$free_gb" -lt "${MIN_DEST_FREE_GB:-20}" ]; then
        local lower
        lower=$(ladder_below "$effective")
        if [ "$lower" -lt "$effective" ]; then
            echo "[$(date)] Destination low (${free_gb}GB free < ${MIN_DEST_FREE_GB}GB) — dropping encode resolution ${effective}p → ${lower}p" >&2
            set_effective_height "$lower"
            effective="$lower"
        else
            echo "[$(date)] Destination low (${free_gb}GB free) but already at lowest ladder rung (${effective}p)" >&2
        fi
    fi
    echo "$effective"
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

    # Determine the effective target height for THIS file, stepping down first
    # if the destination is running low on space.
    local target_height
    target_height=$(maybe_downstep "$dest_base")

    # Check source resolution — skip encoding if already <= effective target
    local src_height
    src_height=$(ffmpeg -i "$source_file" 2>&1 | grep "Video:" | head -1 | grep -oE "[0-9]+x[0-9]+" | head -1 | cut -d"x" -f2)

    if [ -n "$src_height" ] && [ "$src_height" -le "$target_height" ] 2>/dev/null; then
        update_job "$source_file" "$media_type" "converting" 50 "Already ${src_height}p — copying without re-encode"
        cp "$source_file" "$temp_out"
        update_job "$source_file" "$media_type" "transferring" 50 "Copy complete, starting transfer"
        transfer_file "$temp_out" "$rel_path" "$media_type" "$source_file"
        return $?
    fi

    update_job "$source_file" "$media_type" "converting" 0 "Starting ${src_height:-?}p → ${target_height}p conversion"

    local duration
    duration=$(ffmpeg -i "$source_file" 2>&1 | grep "Duration" | head -1 | sed 's/.*Duration: \([^,]*\).*/\1/' | awk -F: '{print ($1*3600)+($2*60)+$3}')
    [ -z "$duration" ] || [ "$duration" = "0" ] && duration=1

    local ffmpeg_video
    ffmpeg_video=$(build_video_flags "$target_height")

    ffmpeg -hide_banner -nostdin -y \
        -i "$source_file" \
        $ffmpeg_video $FFMPEG_AUDIO $FFMPEG_EXTRA \
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
        # Out-of-space on the destination: force a resolution downstep so the
        # next cycle re-encodes this (and subsequent) files smaller. Discard the
        # too-large temp output so it is regenerated at the lower resolution.
        if grep -qiE "No space left on device|write error.*disk|errno 28" "$log_file" 2>/dev/null; then
            if [ "${ADAPTIVE_RESOLUTION:-1}" = "1" ]; then
                local cur lower
                cur=$(get_effective_height)
                lower=$(ladder_below "$cur")
                if [ "$lower" -lt "$cur" ]; then
                    set_effective_height "$lower"
                    echo "[$(date)] Destination full during transfer — dropping resolution ${cur}p → ${lower}p; will re-encode next cycle" >&2
                fi
                rm -f "$local_file"
                update_job "$source_file" "$media_type" "failed" 0 "Destination full — will retry at lower resolution"
                return 1
            fi
            update_job "$source_file" "$media_type" "failed" 50 "Destination full (no space left on device)"
            return 1
        fi
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

# ─── Initial inventory scan ───────────────────────────────────────────
echo "[$(date)] Running initial inventory scan..."

SOURCE_TOTAL=$(find "$SOURCE_MOVIES" "$SOURCE_TV" -type f \( \
    -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" \
    -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.wmv" \
    -o -iname "*.ts" -o -iname "*.flv" -o -iname "*.webm" \
\) 2>/dev/null | wc -l | tr -d ' ' || true)
SOURCE_TOTAL=${SOURCE_TOTAL:-0}

DEST_FIND_CMD="find \"${DEST_MOVIES}\" \"${DEST_TV}\" -type f 2>/dev/null | wc -l"
# Tolerate an unreachable/erroring destination here — a failed count must not
# abort the whole run (set -e + pipefail would otherwise kill it on SSH exit 255).
DEST_DONE=$(ssh -i "$DEST_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    -o UserKnownHostsFile="$INSTALL_DIR/known_hosts" \
    "$DEST_HOST" "$DEST_FIND_CMD" 2>/dev/null | tr -d ' ' || true)
DEST_DONE=${DEST_DONE:-0}
[[ "$DEST_DONE" =~ ^[0-9]+$ ]] || DEST_DONE=0

echo "[$(date)] Source files: $SOURCE_TOTAL | Already on destination: $DEST_DONE | Remaining: $((SOURCE_TOTAL - DEST_DONE))"

# ─── Pre-flight size estimate ─────────────────────────────────────────
# Estimate how much space the converted mirror will need on the destination
# BEFORE encoding anything, and whether it will fit. Best-effort: a failure
# here never blocks the run.
echo "[$(date)] Estimating projected mirror size (this may take a moment for large libraries)..."
SIZE_JSON=$(CONFIG_FILE="$SCRIPT_DIR/config.env" python3 "$SCRIPT_DIR/estimate_size.py" \
    --config "$SCRIPT_DIR/config.env" --target "${TARGET_HEIGHT:-720}" --json 2>/dev/null || echo '')

python3 << PYEOF
import json
with open('$STATE_FILE','r') as f: state=json.load(f)
inv = {
    'source_total': $SOURCE_TOTAL,
    'dest_done': $DEST_DONE,
    'remaining': $SOURCE_TOTAL - $DEST_DONE,
}
raw = '''$SIZE_JSON'''.strip()
if raw:
    try:
        est = json.loads(raw)
        inv['estimated_bytes'] = est.get('estimated_bytes')
        inv['estimated_human'] = est.get('estimated_human')
        inv['source_bytes'] = est.get('source_bytes')
        inv['dest_free_bytes'] = est.get('dest_free_bytes')
        inv['dest_free_human'] = est.get('dest_free_human')
        inv['fits'] = est.get('fits')
        inv['headroom_bytes'] = est.get('headroom_bytes')
        inv['estimate_target_height'] = est.get('target_height')
    except Exception:
        pass
state['inventory'] = inv
# Effective height is sticky across runs (don't bounce resolution back up when
# space frees), but never exceed the configured target — so lowering
# TARGET_HEIGHT in config still takes effect immediately.
_target = int(${TARGET_HEIGHT:-720})
_eff = state.get('runner', {}).get('effective_height') or _target
state.setdefault('runner', {})['effective_height'] = min(int(_eff), _target)
state['runner']['target_height'] = _target
with open('$STATE_FILE','w') as f: json.dump(state,f)
if inv.get('estimated_human'):
    fit = inv.get('fits')
    verdict = 'FITS' if fit else ('WILL NOT FIT' if fit is False else 'dest free unknown')
    print(f"[estimate] Projected mirror: {inv['estimated_human']} | Dest free: {inv.get('dest_free_human','unknown')} | {verdict}")
PYEOF

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
