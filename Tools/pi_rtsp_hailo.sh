#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./pi_rtsp_hailo.sh [RTSP_URL] [HEF_PATH]
#   RTSP_URL default: rtsp://pai.tripnet.be:8554/factorio
#   HEF_PATH default: /home/tripkipke/models/yolov5.hef
#   Optional env: DECODER=avdec_h264|v4l2h264dec, SINK=autovideosink|fakesink, GST_DEBUG=1

RTSP_URL="${1:-rtsp://pai.tripnet.be:8554/factorio}"
HEF_PATH="${2:-/home/tripkipke/models/yolov5.hef}"

# Quick sanity checks
command -v gst-launch-1.0 >/dev/null || { echo "gst-launch-1.0 not found"; exit 3; }
gst-inspect-1.0 hailonet >/dev/null 2>&1 || { echo "GStreamer 'hailonet' plugin not found (install HailoRT plugins)"; exit 4; }
[ -f "$HEF_PATH" ] || { echo "HEF not found at $HEF_PATH"; exit 2; }

DECODER="${DECODER:-avdec_h264}"   # try: DECODER=v4l2h264dec if available
SINK="${SINK:-autovideosink}"      # for headless set: SINK=fakesink

# Test stream quickly (optional):
# gst-launch-1.0 -v rtspsrc location="$RTSP_URL" protocols=tcp latency=100 ! rtph264depay ! h264parse ! "$DECODER" ! $SINK

# Full pipeline with Hailo inference
: "${GST_DEBUG:=1}"
GST_DEBUG="$GST_DEBUG" gst-launch-1.0 -v \
  rtspsrc location="$RTSP_URL" protocols=tcp latency=100 ! \
    rtph264depay ! h264parse ! "$DECODER" ! \
    videoconvert ! videoscale ! video/x-raw,format=RGB,width=1280,height=720 ! \
    hailonet hef-path="$HEF_PATH" ! queue ! hailooverlay ! \
    videoconvert ! "$SINK" sync=false
