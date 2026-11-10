#!/bin/bash
# Unit tests for the transcript script. Run: bash tests/transcript/run_tests.sh
# Sources the script (its main() guard prevents execution) and exercises
# individual functions with faked curl/sleep.

# Fake functions below are invoked by name from the sourced script under
# test, which shellcheck cannot see.
# shellcheck disable=SC2329

SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/roles/system/core/files/usr/bin/transcript"

failures=0
assert_eq() {
    if [[ "$1" == "$2" ]]; then
        echo "ok - $3"
    else
        echo "FAIL - $3 (got '$1', want '$2')"
        failures=$((failures + 1))
    fi
}

export DEEPINFRA_API_TOKEN="test-token"
# shellcheck source=../../../../roles/system/core/files/usr/bin/transcript
# shellcheck disable=SC1091
source "$SCRIPT_UNDER_TEST"

# Fakes defined after sourcing override the script's real commands.
# The fakes count via files: api_call invokes curl inside a command
# substitution (and is itself captured with $(...) below), so counters kept
# in shell variables would be lost to subshells and never reach the asserts.
fake_dir="$(mktemp -d)"
sleeps=()
sleep() { printf '%s\n' "$*" >>"$fake_dir/sleeps"; }
# Pull the file-based counters back into shell variables for assertions.
reload_counters() {
    mapfile -t _curl_log <"$fake_dir/curl"
    curl_calls=${#_curl_log[@]}
    mapfile -t sleeps <"$fake_dir/sleeps"
}

# --- api_call: retries until success ---
: >"$fake_dir/curl"
: >"$fake_dir/sleeps"
curl_calls=0
curl() {
    printf 'x\n' >>"$fake_dir/curl"
    mapfile -t _curl_log <"$fake_dir/curl"
    curl_calls=${#_curl_log[@]}
    if [[ "$curl_calls" -lt 3 ]]; then
        printf 'server boom\n500\n'
    else
        printf 'hello body\n200\n'
    fi
}
out=$(api_call "test" https://example.com)
reload_counters
assert_eq "$out" "hello body" "api_call retries until success"
assert_eq "${#sleeps[@]}" "2" "api_call sleeps twice before third attempt"
assert_eq "${sleeps[0]} ${sleeps[1]}" "2 4" "api_call backoff is 2s then 4s"

# --- api_call: gives up after exactly 3 attempts ---
: >"$fake_dir/curl"
: >"$fake_dir/sleeps"
curl_calls=0
sleeps=()
curl() {
    printf 'x\n' >>"$fake_dir/curl"
    return 1
}
if api_call "always fail" https://example.com >/dev/null 2>&1; then
    echo "FAIL - api_call must fail after 3 attempts"
    failures=$((failures + 1))
else
    echo "ok - api_call fails after exhausting retries"
fi
reload_counters
assert_eq "$curl_calls" "3" "api_call makes exactly 3 attempts"

# --- api_call: persistent 402 surfaces a top-up hint ---
: >"$fake_dir/curl"
: >"$fake_dir/err402"
curl() {
    printf 'prepaid balance\n402\n'
    return 0
}
if api_call "dictation" https://example.com >/dev/null 2>"$fake_dir/err402"; then
    echo "FAIL - api_call must fail on persistent 402"
    failures=$((failures + 1))
else
    echo "ok - api_call fails on persistent 402"
fi
if grep -q "402" "$fake_dir/err402" && grep -Eqi "top up|recharge|balance" "$fake_dir/err402"; then
    echo "ok - 402 error hints at topping up the balance"
else
    echo "FAIL - 402 error must hint at topping up the balance"
    failures=$((failures + 1))
fi

# --- format_txt ---
out=$(printf '{"text":"  hello world"}' | format_txt)
assert_eq "$out" "hello world" "format_txt strips leading spaces"

# --- transcribe_dictation: smart mode, inline flac, no vocab without file ---
gemini_key="test-key"
vocabulary_file="/nonexistent"
fake_flac="$(mktemp)"
printf 'flac-bytes' > "$fake_flac"
api_call() { cat >"$fake_dir/req.json"; printf '%s' '{"steps":[{"content":[{"type":"text","text":"Bonjour. "}],"bogus":1},{"content":[]},{"content":[{"type":"text","text":"Suite."}]}]}'; }
clean_level="smart"
out=$(transcribe_dictation "$fake_flac")
assert_eq "$out" "Bonjour. Suite." "transcribe_dictation joins step texts"
jq -e '.generation_config.transcription_config.mode == "smart"' "$fake_dir/req.json" >/dev/null \
    && echo "ok - smart mode requested" \
    || { echo "FAIL - smart mode not requested"; failures=$((failures + 1)); }
jq -e '.generation_config.transcription_config | has("custom_vocabulary") | not' "$fake_dir/req.json" >/dev/null \
    && echo "ok - custom_vocabulary omitted without a file" \
    || { echo "FAIL - custom_vocabulary present without a file"; failures=$((failures + 1)); }
jq -e '.model == "models/gemini-3.5-transcribe" and .input[0].mime_type == "audio/flac" and (.input[0].data | type == "string")' "$fake_dir/req.json" >/dev/null \
    && echo "ok - inline flac input and model id" \
    || { echo "FAIL - model or inline input wrong"; failures=$((failures + 1)); }

# --- transcribe_dictation: raw level -> verbatim mode ---
clean_level="raw"
out=$(transcribe_dictation "$fake_flac")
jq -e '.generation_config.transcription_config.mode == {"type": "verbatim"}' "$fake_dir/req.json" >/dev/null \
    && echo "ok - raw level requests verbatim" \
    || { echo "FAIL - raw level must request verbatim"; failures=$((failures + 1)); }

# --- transcribe_dictation: vocabulary injected when the file exists ---
vocabulary_file="$fake_dir/vocab"
printf 'hyprland\nwaybar\n' > "$vocabulary_file"
out=$(transcribe_dictation "$fake_flac")
jq -e '.generation_config.transcription_config.custom_vocabulary == ["hyprland","waybar"]' "$fake_dir/req.json" >/dev/null \
    && echo "ok - custom_vocabulary injected" \
    || { echo "FAIL - custom_vocabulary not injected"; failures=$((failures + 1)); }
rm -f "$vocabulary_file"

# --- transcribe_dictation: API failure and empty text propagate ---
api_call() { return 1; }
if transcribe_dictation "$fake_flac" 2>/dev/null; then
    echo "FAIL - API failure must fail transcription"
    failures=$((failures + 1))
else
    echo "ok - API failure fails transcription"
fi
api_call() { printf '%s' '{"steps":[]}'; }
if transcribe_dictation "$fake_flac" 2>/dev/null; then
    echo "FAIL - empty transcript must fail transcription"
    failures=$((failures + 1))
else
    echo "ok - empty transcript fails transcription"
fi

# --- transcribe_dictation: >128 KiB of audio must not die on MAX_ARG_STRLEN ---
clean_level="smart"
api_call() { cat >"$fake_dir/req.json"; printf '%s' '{"steps":[{"content":[{"type":"text","text":"ok"}]}]}'; }
big_flac="$(mktemp)"
head -c 150000 /dev/zero > "$big_flac"
if out=$(transcribe_dictation "$big_flac"); then
    echo "ok - 150 KiB audio survives the argv limit"
else
    echo "FAIL - large audio must transcribe (MAX_ARG_STRLEN regression)"
    failures=$((failures + 1))
fi
jq -e '(.input[0].data | length) > 190000' "$fake_dir/req.json" >/dev/null \
    && echo "ok - large request captured with full payload" \
    || { echo "FAIL - large request payload not captured"; failures=$((failures + 1)); }
assert_eq "$(find /tmp -maxdepth 1 -name 'transcript-b64-*.txt' | wc -l)" "0" "b64 temp file removed after transcription"
rm -f "$big_flac"
rm -f "$fake_flac"
# Restore the script's init value ("smart"): a later assert checks the
# default clean level, and this block mutated the global to exercise raw mode.
clean_level="smart"

# --- has_speech: punctuation-only whisper output is not speech ---
if has_speech "" || has_speech "..." || has_speech " .  "; then
    echo "FAIL - punctuation-only/empty text must not count as speech"
    failures=$((failures + 1))
else
    echo "ok - punctuation-only/empty text is not speech"
fi
if has_speech "hello"; then
    echo "ok - real text counts as speech"
else
    echo "FAIL - real text must count as speech"
    failures=$((failures + 1))
fi
if has_speech " Bonjour, ça va "; then
    echo "ok - accented non-ASCII text counts as speech"
else
    echo "FAIL - accented non-ASCII text must count as speech"
    failures=$((failures + 1))
fi

# --- job markers ---
jobs_dir="$(mktemp -d)"
job_state transcribing
# Expand BASHPID here: inside $(cat ...) it would be the cat subshell's pid.
marker="$jobs_dir/job-$BASHPID"
assert_eq "$(cat "$marker")" "transcribing" "job_state writes its marker"
job_clear
assert_eq "$(find "$jobs_dir" -name 'job-*' | wc -l)" "0" "job_clear removes its marker"
rm -rf "$jobs_dir"

# --- preserve_rejected: keeps non-empty audio, ignores empty/absent ---
probe="$(mktemp /tmp/recording_probeXXXXXX.wav)"
printf 'wav-bytes' > "$probe"
preserve_rejected "$probe"
kept="$(find /tmp -maxdepth 1 -name 'transcript-rejected-*.wav' -newer "$fake_dir/curl" -print -quit 2>/dev/null)"
if [[ -n "$kept" ]] && [[ "$(cat "$kept" 2>/dev/null)" == "wav-bytes" ]] && [[ ! -e "$probe" ]]; then
    echo "ok - preserve_rejected moves non-empty audio out of the trap's reach"
    rm -f "$kept"
else
    echo "FAIL - preserve_rejected did not preserve the audio"
    failures=$((failures + 1))
    rm -f "$probe" /tmp/transcript-rejected-*.wav
fi
: > "$probe"
preserve_rejected "$probe"
leftover="$(find /tmp -maxdepth 1 -name 'transcript-rejected-*.wav' -print -quit 2>/dev/null)"
if [[ -e "$probe" ]] && [[ -z "$leftover" ]]; then
    echo "ok - preserve_rejected skips empty files (left for trap cleanup)"
    rm -f "$probe"
else
    echo "FAIL - preserve_rejected must skip empty files"
    failures=$((failures + 1))
    rm -f "$probe" /tmp/transcript-rejected-*.wav
fi

# --- default clean level (script init value, before parse_args mutations) ---
assert_eq "$clean_level" "smart" "default clean level is smart"

# --- start_recording must NOT register the live recording for trap cleanup ---
# (the start invocation exits immediately; its EXIT trap must not delete the
# wav arecord is writing — registration belongs to the detached processing job)
jobs_dir="$(mktemp -d)"
recording_info="$(mktemp)"
arecord() {
    sleep 30 &
}
# Reset in test scope (shellcheck cannot see the sourced script's assignment).
temp_files=()
start_recording
assert_eq "${#temp_files[@]}" "0" "start_recording leaves the live recording out of trap cleanup"
kill "$(awk '{print $1}' "$recording_info")" 2>/dev/null || true
rm -f "$recording_info" "$(sed 's/^[0-9]* //' "$recording_info" 2>/dev/null)" /tmp/recording_*.wav
rm -rf "$jobs_dir"
unset -f arecord

# --- stop_recording detaches processing and frees the toggle ---
# command sleep bypasses the fake sleep above (used by the detached job's
# real timings and by the waits below).
jobs_dir="$(mktemp -d)"
recording_info="$(mktemp)"
last_out_file="$(mktemp)"
arecord() {
    command sleep 30
}
temp_files=()
start_recording
read -r rpid wavpath < "$recording_info"
printf 'silent-but-nonempty-wav' > "$wavpath"
stop_recording
assert_eq "$( [[ -f "$recording_info" ]] && echo present || echo gone )" "gone" "stop_recording frees the toggle immediately"
command sleep 1.5
assert_eq "$(find "$jobs_dir" -name 'job-*' | wc -l)" "0" "detached job cleans its marker (no-speech path)"
rejected="$(find /tmp -maxdepth 1 -name 'transcript-rejected-*.wav' -print -quit 2>/dev/null)"
if [[ ! -e "$wavpath" ]] && [[ -n "$rejected" ]]; then
    echo "ok - no-speech path preserves the recording for manual recovery"
    rm -f "$rejected"
else
    echo "FAIL - no-speech path must preserve the recording"
    failures=$((failures + 1))
    rm -f "$wavpath" /tmp/transcript-rejected-*.wav
fi
kill "$rpid" 2>/dev/null || true
rm -rf "$jobs_dir" "$recording_info" "$last_out_file"
unset -f arecord

# --- load_token: env then file ---
assert_eq "$(load_token)" "test-token" "load_token prefers the env var"
unset DEEPINFRA_API_TOKEN
token_file="$(mktemp)"
printf 'file-token\n' > "$token_file"
assert_eq "$(load_token)" "file-token" "load_token reads the token file"
rm -f "$token_file"
export DEEPINFRA_API_TOKEN="test-token"

# --- load_gemini_key: env then file ---
export GEMINI_API_KEY="gem-key-env"
assert_eq "$(load_gemini_key)" "gem-key-env" "load_gemini_key prefers the env var"
unset GEMINI_API_KEY
gemini_key_file="$(mktemp)"
printf 'gem-key-file\n' > "$gemini_key_file"
assert_eq "$(load_gemini_key)" "gem-key-file" "load_gemini_key reads the key file"
rm -f "$gemini_key_file"
export GEMINI_API_KEY="gem-key-env"

# --- emit_vocabulary: file -> JSON array; absent/empty -> nothing ---
vocabulary_file="$(mktemp)"
printf 'hyprland\n\n# comment\n   \nwaybar\n' > "$vocabulary_file"
assert_eq "$(emit_vocabulary)" '["hyprland","waybar"]' "emit_vocabulary skips blanks and comments"
rm -f "$vocabulary_file"
assert_eq "$(emit_vocabulary)" "" "emit_vocabulary silent without a file"
vocabulary_file="$(mktemp)"
: > "$vocabulary_file"
assert_eq "$(emit_vocabulary)" "" "emit_vocabulary silent when the file is empty"
rm -f "$vocabulary_file"

# --- parse_args ---
clean_level="smart"; srt_flag=0; input_file=""
parse_args myfile.wav --srt
assert_eq "$input_file" "myfile.wav" "parse_args captures the file"
assert_eq "$srt_flag" "1" "parse_args reads --srt"

clean_level="smart"; srt_flag=0; input_file=""
parse_args --raw
assert_eq "$clean_level" "raw" "--raw selects raw level"
assert_eq "$input_file" "" "--raw sets no file"

if (parse_args --clean full) 2>/dev/null; then
    echo "FAIL - --clean must be rejected"
    failures=$((failures + 1))
else
    echo "ok - --clean is rejected"
fi

rm -rf "$fake_dir"

# --- summary ---
if [[ "$failures" -eq 0 ]]; then
    echo "All tests passed."
else
    echo "$failures test(s) failed."
    exit 1
fi
