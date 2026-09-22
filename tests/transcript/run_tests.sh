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

# --- llm_clean: returns model content ---
api_call() { printf '%s' '{"choices":[{"message":{"content":"Cleaned text."}}]}'; }
out=$(printf 'raw txt' | llm_clean light)
assert_eq "$out" "Cleaned text." "llm_clean returns model content"

# --- llm_clean: falls back to input on API failure ---
api_call() {
    echo "boom" >&2
    return 1
}
out=$(printf 'raw txt' | llm_clean full)
assert_eq "$out" "raw txt" "llm_clean falls back to input on API failure"

# --- llm_clean: empty input passes through without API call ---
api_call() { printf '%s' '{"choices":[{"message":{"content":"should not be called"}}]}'; }
out=$(printf '' | llm_clean light)
assert_eq "$out" "" "llm_clean passes empty input through"

# --- format_txt ---
out=$(printf '{"text":"  hello world"}' | format_txt)
assert_eq "$out" "hello world" "format_txt strips leading spaces"

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

# --- default clean level (script init value, before parse_args mutations) ---
assert_eq "$clean_level" "full" "default clean level is full"

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
last_raw_file="$(mktemp)"
last_out_file="$(mktemp)"
arecord() {
    command sleep 30
}
temp_files=()
start_recording
read -r rpid wavpath < "$recording_info"
stop_recording
assert_eq "$( [[ -f "$recording_info" ]] && echo present || echo gone )" "gone" "stop_recording frees the toggle immediately"
command sleep 1.5
assert_eq "$(find "$jobs_dir" -name 'job-*' | wc -l)" "0" "detached job cleans its marker (no-speech path)"
assert_eq "$( [[ -e "$wavpath" ]] && echo leaked || echo cleaned )" "cleaned" "detached job removes its wav via trap"
kill "$rpid" 2>/dev/null || true
rm -rf "$jobs_dir" "$recording_info" "$last_raw_file" "$last_out_file"
unset -f arecord

# --- load_token: env then file ---
assert_eq "$(load_token)" "test-token" "load_token prefers the env var"
unset DEEPINFRA_API_TOKEN
token_file="$(mktemp)"
printf 'file-token\n' > "$token_file"
assert_eq "$(load_token)" "file-token" "load_token reads the token file"
rm -f "$token_file"
export DEEPINFRA_API_TOKEN="test-token"

# --- parse_args ---
clean_level="light"; srt_flag=0; input_file=""
parse_args --clean full myfile.wav --srt
assert_eq "$clean_level" "full" "parse_args reads --clean level"
assert_eq "$input_file" "myfile.wav" "parse_args captures the file"
assert_eq "$srt_flag" "1" "parse_args reads --srt"

clean_level="light"; srt_flag=0; input_file=""
parse_args --raw
assert_eq "$clean_level" "raw" "--raw selects raw level"
assert_eq "$input_file" "" "--raw sets no file"

rm -rf "$fake_dir"

# --- summary ---
if [[ "$failures" -eq 0 ]]; then
    echo "All tests passed."
else
    echo "$failures test(s) failed."
    exit 1
fi
