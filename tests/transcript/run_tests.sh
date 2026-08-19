#!/bin/bash
# Unit tests for the transcript script. Run: bash tests/transcript/run_tests.sh
# Sources the script (its main() guard prevents execution) and exercises
# individual functions with faked curl/dunstify/sleep.

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
dunstify() { return 0; }
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

# --- set_state ---
state_file="$(mktemp)"
set_state "recording"
assert_eq "$(cat "$state_file")" "recording" "set_state writes the state file"
rm -f "$state_file"

# --- start_recording must NOT register the live recording for trap cleanup ---
# (the start invocation exits immediately; its EXIT trap must not delete the
# wav arecord is writing — registration belongs to the stop invocation)
state_file="$(mktemp)"
recording_info="$(mktemp)"
arecord() {
    sleep 30 &
}
dunstify() {
    return 0
}
# Reset in test scope (shellcheck cannot see the sourced script's assignment).
temp_files=()
start_recording
assert_eq "${#temp_files[@]}" "0" "start_recording leaves the live recording out of trap cleanup"
kill "$(awk '{print $1}' "$recording_info")" 2>/dev/null || true
rm -f "$recording_info" "$state_file" "$(sed 's/^[0-9]* [0-9]* //' "$recording_info" 2>/dev/null)" /tmp/recording_*.wav
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
