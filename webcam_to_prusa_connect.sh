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
