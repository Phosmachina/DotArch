#!/bin/bash
# waybar-transcript.sh - Waybar custom module for the transcript script.
# Reads the state file and emits Waybar module JSON.

state_file="${XDG_RUNTIME_DIR:-/tmp}/transcript.state"
state="idle"
[[ -r "$state_file" ]] && state=$(<"$state_file")

case "$state" in
    recording) icon="🎤"; class="recording" ;;
    transcribing) icon="⏳"; class="transcribing" ;;
    error) icon="❌"; class="error" ;;
    *) icon="🎙️"; class="idle" ;;
esac

printf '{"text": "%s", "class": "%s"}\n' "$icon" "$class"
