#!/bin/bash
# waybar-transcript.sh - Waybar custom module for the transcript script.
# Aggregates the live recording (/tmp/recording_info + pid) and background
# processing jobs (marker files in the transcript-jobs dir) into one state.

recording_info="/tmp/recording_info"
jobs_dir="${XDG_RUNTIME_DIR:-/tmp}/transcript-jobs"

state="idle"
if [[ -r "$recording_info" ]]; then
    read -r pid _ < "$recording_info"
    kill -0 "$pid" 2>/dev/null && state="recording"
fi

if [[ "$state" != "recording" ]]; then
    # Priority: transcribing > cleaning > error (work in progress wins;
    # a finished job's error stays visible until the next recording).
    for f in "$jobs_dir"/job-*; do
        [[ -e "$f" ]] || continue
        phase=$(<"$f")
        pid="${f##*/job-}"
        kill -0 "$pid" 2>/dev/null || [[ "$phase" == "error" ]] || continue
        case "$phase" in
            transcribing) state="transcribing" ;;
            cleaning) [[ "$state" == "idle" || "$state" == "error" ]] && state="cleaning" ;;
            error) [[ "$state" == "idle" ]] && state="error" ;;
        esac
        [[ "$state" == "transcribing" ]] && break
    done
fi

case "$state" in
    recording) text="🎤"; class="recording" ;;
    transcribing) text="⏳"; class="transcribing" ;;
    cleaning) text="✨ clean"; class="cleaning" ;;
    error) text="❌"; class="error" ;;
    *) text="🎙️"; class="idle" ;;
esac

printf '{"text": "%s", "class": "%s"}\n' "$text" "$class"
