#!/bin/bash
# waybar-transcript.sh - Waybar custom module for the transcript script.
# Reads the state file and emits Waybar module JSON.

state_file="${XDG_RUNTIME_DIR:-/tmp}/transcript.state"
state="idle"
[[ -r "$state_file" ]] && state=$(<"$state_file")

case "$state" in
    recording) text="🎤"; class="recording" ;;
    transcribing) text="⏳"; class="transcribing" ;;
    cleaning) text="✨ clean"; class="cleaning" ;;
    error) text="❌"; class="error" ;;
    *) text="🎙️"; class="idle" ;;
esac

printf '{"text": "%s", "class": "%s"}\n' "$text" "$class"
