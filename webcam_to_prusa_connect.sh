#!/bin/bash
PRUSA_URL=https://webcam.connect.prusa3d.com/c/snapshot
FRAME_CAPTURE_DELAY=${FRAME_CAPTURE_DELAY:-0.5}
CAMERA_CYCLE_DELAY=${CAMERA_CYCLE_DELAY:-9}
CONNECTION_TIMEOUT_DELAY=${CONNECTION_TIMEOUT_DELAY:-5}
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source ${SCRIPT_DIR}/settings.conf || exit 1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Build deterministic fingerprints: camera0000000001, camera0000000002, etc.
# Prusa Connect uses these to identify which camera slot a snapshot belongs to.
FINGERPRINTS=()
for i in $(seq 1 ${#CAMERA_NAMES[@]}); do
    FINGERPRINTS+=($(printf "camera%010d" $i))
done

# Use a RAM-backed temp directory so frames are never written to the SD card.
TMPDIR=$(mktemp -d)
trap "log 'Shutting down...'; kill ${FFMPEG_PIDS[@]} 2>/dev/null; rm -rf $TMPDIR" EXIT

log "Starting with ${#CAMERA_NAMES[@]} camera(s)"

# Maximum age of a frame file in seconds before it is considered stale.
# If ffmpeg freezes without dying, its output file stops updating — this
# threshold lets us detect and skip those frames rather than re-uploading stale data.
FRAME_MAX_AGE=10

# Starts (or restarts) the ffmpeg process for camera index $1.
# Sets manual focus first, then launches ffmpeg in the background with -update 1
# so it continuously overwrites a single JPEG rather than creating new files.
# Writes the new PID into FFMPEG_PIDS[$1].
start_ffmpeg() {
    local i=$1
    local OUTFILE="$TMPDIR/frame_${i}.jpg"

    log "Camera $((i+1)) '${CAMERA_NAMES[$i]}': setting focus to ${CAMERA_FOCUS[$i]}"
    v4l2-ctl --device=${CAMERA_DEVICES[$i]} --set-ctrl=focus_automatic_continuous=0
    v4l2-ctl --device=${CAMERA_DEVICES[$i]} --set-ctrl=focus_absolute=${CAMERA_FOCUS[$i]}

    ffmpeg -f v4l2 \
        -input_format mjpeg \
        -framerate 10 \
        -video_size ${CAMERA_RESOLUTIONS[$i]} \
        -i ${CAMERA_DEVICES[$i]} \
        -update 1 \
        -q:v ${CAMERA_JPEG_QUALITY[$i]} \
        "$OUTFILE" 2>/dev/null &
    FFMPEG_PIDS[$i]=$!
}

# Start one ffmpeg process per camera.
FFMPEG_PIDS=()
for i in "${!CAMERA_NAMES[@]}"; do
    start_ffmpeg $i
    log "Camera $((i+1)) '${CAMERA_NAMES[$i]}': device=${CAMERA_DEVICES[$i]} resolution=${CAMERA_RESOLUTIONS[$i]} ffmpeg_pid=${FFMPEG_PIDS[$i]}"
done

log "Waiting 3s for cameras to initialize..."
sleep 3

UPLOAD_COUNT=0

# Track whether each camera has logged its first successful upload.
# Gives immediate confirmation at startup that each camera is working.
FIRST_SUCCESS=()
for i in "${!CAMERA_NAMES[@]}"; do
    FIRST_SUCCESS[$i]=0
done

while true; do
    for i in "${!CAMERA_NAMES[@]}"; do
        OUTFILE="$TMPDIR/frame_${i}.jpg"

        # --- ffmpeg watchdog ---
        # Check if this camera's ffmpeg process is still alive.
        # If it has died (e.g. camera unplugged), restart it and wait for it
        # to produce its first frame before attempting an upload.
        if ! kill -0 "${FFMPEG_PIDS[$i]}" 2>/dev/null; then
            log "WARN: Camera $((i+1)) '${CAMERA_NAMES[$i]}': ffmpeg (pid ${FFMPEG_PIDS[$i]}) died, restarting..."
            start_ffmpeg $i
            log "INFO: Camera $((i+1)) '${CAMERA_NAMES[$i]}': restarted ffmpeg (pid ${FFMPEG_PIDS[$i]}), waiting 3s..."
            sleep 3
        fi

        if [ ! -f "$OUTFILE" ]; then
            log "ERROR: Camera $((i+1)) '${CAMERA_NAMES[$i]}': no frame available"
            continue
        fi

        # --- Frame staleness check ---
        # A running ffmpeg process can still freeze without crashing. Compare
        # the frame file's modification time against FRAME_MAX_AGE and skip
        # the upload if the file hasn't been updated recently.
        FRAME_AGE=$(( $(date +%s) - $(stat -c %Y "$OUTFILE") ))
        if (( FRAME_AGE > FRAME_MAX_AGE )); then
            log "WARN: Camera $((i+1)) '${CAMERA_NAMES[$i]}': frame is ${FRAME_AGE}s old (max ${FRAME_MAX_AGE}s), skipping"
            continue
        fi

        # Copy the frame before uploading to avoid a race with ffmpeg, which
        # may overwrite the file mid-transfer.
        cp "$OUTFILE" "${OUTFILE}.send"

        # Upload the snapshot to Prusa Connect.
        # --connect-timeout limits only the TCP handshake (fast failure on no route).
        # --max-time covers the entire transfer; 30s is needed for large JPEGs on
        # slow connections (1920x1080 at high quality can be 1-3 MB).
        # Capture curl's exit code separately to distinguish timeout (28) from
        # other network failures when the HTTP status is 000.
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
            -X PUT "$PRUSA_URL" \
            -H "accept: */*" \
            -H "content-type: image/jpg" \
            -H "fingerprint: ${FINGERPRINTS[$i]}" \
            -H "token: ${TOKENS[$i]}" \
            --data-binary "@${OUTFILE}.send" \
            --no-progress-meter \
            --connect-timeout "$CONNECTION_TIMEOUT_DELAY" \
            --max-time 30)
        CURL_EXIT=$?

        if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "204" ]]; then
            (( UPLOAD_COUNT++ ))
            # Log the first success per camera so startup can be confirmed quickly.
            if (( FIRST_SUCCESS[$i] == 0 )); then
                log "INFO: Camera $((i+1)) '${CAMERA_NAMES[$i]}': first upload successful"
                FIRST_SUCCESS[$i]=1
            fi
            # Periodic milestone log to confirm ongoing operation without flooding the journal.
            if (( UPLOAD_COUNT % 100 == 0 )); then
                log "INFO: Camera $((i+1)) '${CAMERA_NAMES[$i]}': $UPLOAD_COUNT total uploads OK"
            fi
        elif [[ "$HTTP_STATUS" == "429" ]]; then
            # Prusa Connect is rate-limiting us. Back off for a full cycle before retrying
            # rather than immediately hammering the endpoint again.
            log "WARN: Camera $((i+1)) '${CAMERA_NAMES[$i]}': rate limited (429), backing off ${CAMERA_CYCLE_DELAY}s"
            sleep "$CAMERA_CYCLE_DELAY"
        elif [[ "$HTTP_STATUS" == "000" ]]; then
            # curl returned no HTTP status — the request never completed.
            # Exit code 28 means --max-time was exceeded (upload too slow for the connection).
            # Any other exit code indicates a lower-level network failure.
            if (( CURL_EXIT == 28 )); then
                log "WARN: Camera $((i+1)) '${CAMERA_NAMES[$i]}': upload timed out (curl exit 28)"
            else
                log "WARN: Camera $((i+1)) '${CAMERA_NAMES[$i]}': network failure, no response (curl exit $CURL_EXIT)"
            fi
        else
            log "WARN: Camera $((i+1)) '${CAMERA_NAMES[$i]}': unexpected HTTP status $HTTP_STATUS"
        fi

        sleep "$FRAME_CAPTURE_DELAY"
    done
    sleep "$CAMERA_CYCLE_DELAY"
done
