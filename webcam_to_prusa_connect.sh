#!/bin/bash
PRUSA_URL=https://connect.prusa3d.com/c/snapshot
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
trap "log 'Shutting down...'; rm -rf $TMPDIR" EXIT

log "Starting with ${#CAMERA_NAMES[@]} camera(s)"
for i in "${!CAMERA_NAMES[@]}"; do
    log "Camera $((i+1)) '${CAMERA_NAMES[$i]}': snapshots from ${CAMERA_SNAPSHOT_URLS[$i]}"
done

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

        # --- Fetch a fresh frame ---
        # go2rtc owns the camera and serves its latest frame over HTTP. A failed
        # fetch means go2rtc is down or has no frame; skip this camera this cycle.
        curl -sf -o "$OUTFILE" --max-time 10 "${CAMERA_SNAPSHOT_URLS[$i]}"
        FETCH_EXIT=$?
        if (( FETCH_EXIT != 0 )); then
            log "WARN: Camera $((i+1)) '${CAMERA_NAMES[$i]}': no frame from ${CAMERA_SNAPSHOT_URLS[$i]} (curl exit $FETCH_EXIT)"
            continue
        fi

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
            --data-binary "@${OUTFILE}" \
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
