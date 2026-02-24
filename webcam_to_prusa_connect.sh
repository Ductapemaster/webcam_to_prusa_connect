#!/bin/bash
PRUSA_URL=https://webcam.connect.prusa3d.com/c/snapshot
FRAME_CAPTURE_DELAY=${FRAME_CAPTURE_DELAY:-0.5}
CAMERA_CYCLE_DELAY=${CAMERA_CYCLE_DELAY:-9}
CONNECTION_TIMEOUT_DELAY=${CONNECTION_TIMEOUT_DELAY:-5}
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source ${SCRIPT_DIR}/settings.conf || exit 1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

FINGERPRINTS=()
for i in $(seq 1 ${#CAMERA_NAMES[@]}); do
    FINGERPRINTS+=($(printf "camera%010d" $i))
done

TMPDIR=$(mktemp -d)
trap "log 'Shutting down...'; kill ${FFMPEG_PIDS[@]} 2>/dev/null; rm -rf $TMPDIR" EXIT

log "Starting with ${#CAMERA_NAMES[@]} camera(s)"

FFMPEG_PIDS=()
for i in "${!CAMERA_NAMES[@]}"; do
    OUTFILE="$TMPDIR/frame_${i}.jpg"

    log "Camera $((i+1)) '${CAMERA_NAMES[$i]}': setting focus to ${CAMERA_FOCUS[$i]}"
    v4l2-ctl --device=${CAMERA_DEVICES[$i]} --set-ctrl=focus_automatic_continuous=0
    v4l2-ctl --device=${CAMERA_DEVICES[$i]} --set-ctrl=focus_absolute=${CAMERA_FOCUS[$i]}

    ffmpeg -f v4l2 \
        -input_format mjpeg \
        -framerate 10 \
        -video_size ${CAMERA_RESOLUTIONS[$i]} \
        -i ${CAMERA_DEVICES[$i]} \
        -update 1 \
        -q:v 2 \
        "$OUTFILE" 2>/dev/null &
    FFMPEG_PIDS+=($!)
    log "Camera $((i+1)) '${CAMERA_NAMES[$i]}': device=${CAMERA_DEVICES[$i]} resolution=${CAMERA_RESOLUTIONS[$i]} ffmpeg_pid=${FFMPEG_PIDS[$i]}"
done

log "Waiting 3s for cameras to initialize..."
sleep 3

UPLOAD_COUNT=0

while true; do
    for i in "${!CAMERA_NAMES[@]}"; do
        OUTFILE="$TMPDIR/frame_${i}.jpg"

        if [ ! -f "$OUTFILE" ]; then
            log "ERROR: Camera $((i+1)) '${CAMERA_NAMES[$i]}': no frame available"
            continue
        fi

        cp "$OUTFILE" "${OUTFILE}.send"
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
            -X PUT "$PRUSA_URL" \
            -H "accept: */*" \
            -H "content-type: image/jpg" \
            -H "fingerprint: ${FINGERPRINTS[$i]}" \
            -H "token: ${TOKENS[$i]}" \
            --data-binary "@${OUTFILE}.send" \
            --no-progress-meter \
            --compressed \
            --max-time "$CONNECTION_TIMEOUT_DELAY")

        if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "204" ]]; then
            (( UPLOAD_COUNT++ ))
            if (( UPLOAD_COUNT % 100 == 0 )); then
                log "INFO: Camera $((i+1)) '${CAMERA_NAMES[$i]}': $UPLOAD_COUNT uploads OK"
            fi
        else
            log "WARN: Camera $((i+1)) '${CAMERA_NAMES[$i]}': unexpected HTTP status $HTTP_STATUS"
        fi

        sleep "$FRAME_CAPTURE_DELAY"
    done
    sleep "$CAMERA_CYCLE_DELAY"
done

