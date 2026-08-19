# Transcript Script Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore `/usr/bin/transcript` as a working dictation tool (curl + DeepInfra with retries, two-level LLM cleanup, Wayland paste, waybar pulsing pill), deployed host-side for manual testing with VoxType untouched.

**Architecture:** Extend the existing single-file bash script (`roles/system/core/files/usr/bin/transcript`) with an API layer shared by whisper and LLM calls, a state file driving a new waybar custom module, and a sourceable main guard enabling bash unit tests. Waybar pieces follow the existing `custom/voxtype` pattern in `roles/desktop/waybar/`.

**Tech Stack:** Bash, curl, jq, sox, ffmpeg, arecord, wl-clipboard, wtype, dunstify, Waybar (JSON module + CSS), Ansible (deploy only).

**Spec:** `docs/superpowers/specs/2026-08-19-transcript-restore-design.md`

## Global Constraints

- The DeepInfra token is NEVER written to any committed file (script, tests, plan, docs). It lives only in `~/.config/transcript/token` (mode 600) or `$DEEPINFRA_API_TOKEN`.

> **Execution addenda (2026-08-19):** two defects surfaced during Task 4 live
> smoke tests and were fixed in commits `877a820` (temp files leaked: register
> returned paths parent-side since `$(...)` subshells lose array mutations)
> and `59fdeb6` (whisper 200 with empty/punctuation-only text is now a benign
> "No speech detected" via `has_speech()`, not a red error). The Task 1 script
> block below predates these fixes — the committed script is authoritative.

- VoxType is untouched this phase: no edits to `roles/apps/voxtype/`, keybindings, `roles/profiles/desktop-hyprland/tasks/main.yml`, or `group_vars/`.
- File/SRT mode semantics unchanged (backend call only). LLM cleanup applies to dictation mode only.
- Dependency deltas: drop `deepctl`, `xclip`, `xdotool`; add `wl-clipboard`, `wtype`; keep `arecord`, `sox`, `ffmpeg`, `jq`, `dunstify`.
- Keep the existing sox silence-removal parameters; remove the `tempo 1.2` speedup entirely.
- Bash strictness: `set -uo pipefail` (no `-e`; errors handled explicitly).
- `shellcheck` (available at `/usr/sbin/shellcheck`) must report no warnings for every shell file touched.
- YAML/Ansible conventions per `AGENTS.md` apply to any task files touched (none planned beyond waybar templates/css).

---

### Task 1: Rewrite `transcript` script + unit tests

**Files:**
- Modify: `roles/system/core/files/usr/bin/transcript` (full rewrite, content below)
- Create: `tests/transcript/run_tests.sh`

**Interfaces:**
- Produces (used by tests in this task): `api_call DESCRIPTION CURL_ARGS...` (prints body, returns non-zero after 3 failed attempts, backoff `sleep 2` then `sleep 4`); `load_token` (prints token from env or file); `llm_clean LEVEL` (stdin→stdout, levels `light|full`, falls back to input on failure); `format_txt`, `format_srt` (unchanged jq filters); `set_state STATE`; `parse_args` (sets globals `clean_level`, `srt_flag`, `input_file`).
- Produces (used by Task 3): state file `$XDG_RUNTIME_DIR/transcript.state` (fallback `/tmp/transcript.state`) containing `idle|recording|transcribing|error`.
- Produces (used by Task 2): constant `llm_model="Qwen/Qwen3.5-9B"` (line near top of script) and endpoint `${api_base}/v1/openai/chat/completions`.
- Guard: script only runs `main "$@"` when executed directly (`BASH_SOURCE == $0`), so tests can source it.

- [ ] **Step 1: Write the failing test suite**

Create `tests/transcript/run_tests.sh`:

```bash
#!/bin/bash
# Unit tests for the transcript script. Run: bash tests/transcript/run_tests.sh
# Sources the script (its main() guard prevents execution) and exercises
# individual functions with faked curl/dunstify/sleep.

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
sleeps=()
sleep() { sleeps+=("$*"); }
dunstify() { return 0; }

# --- api_call: retries until success ---
curl_calls=0
curl() {
    curl_calls=$((curl_calls + 1))
    if [[ "$curl_calls" -lt 3 ]]; then
        printf 'server boom\n500\n'
    else
        printf 'hello body\n200\n'
    fi
}
out=$(api_call "test" https://example.com)
assert_eq "$out" "hello body" "api_call retries until success"
assert_eq "${#sleeps[@]}" "2" "api_call sleeps twice before third attempt"
assert_eq "${sleeps[0]} ${sleeps[1]}" "2 4" "api_call backoff is 2s then 4s"

# --- api_call: gives up after exactly 3 attempts ---
curl_calls=0
sleeps=()
curl() {
    curl_calls=$((curl_calls + 1))
    return 1
}
if api_call "always fail" https://example.com >/dev/null 2>&1; then
    echo "FAIL - api_call must fail after 3 attempts"
    failures=$((failures + 1))
else
    echo "ok - api_call fails after exhausting retries"
fi
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

# --- summary ---
if [[ "$failures" -eq 0 ]]; then
    echo "All tests passed."
else
    echo "$failures test(s) failed."
    exit 1
fi
```

- [ ] **Step 2: Run tests to verify they fail against the current script**

Run: `bash tests/transcript/run_tests.sh`
Expected: FAIL — the current script calls `main "$@"` unconditionally when sourced (check_dependencies exits on missing `deepctl`, aborting the test shell), and `api_call`/`llm_clean`/`set_state`/`parse_args` don't exist. Any abort or FAIL lines confirm the tests exercise new behavior.

- [ ] **Step 3: Rewrite the script**

Replace the entire content of `roles/system/core/files/usr/bin/transcript` with:

```bash
#!/bin/bash
#
# transcript - push-to-talk dictation and file transcription via DeepInfra.
#
# Usage:
#   transcript [--clean light|full|raw]        toggle dictation recording
#   transcript FILE [--srt]                    transcribe an audio/video file
#
# Dictation pipeline: arecord -> sox silence removal -> ffmpeg AAC ->
# whisper (curl) -> optional LLM cleanup -> wl-copy + wtype.

set -uo pipefail

dependencies=("arecord" "curl" "jq" "wl-copy" "wtype" "dunstify" "sox" "ffmpeg")

inference_model="openai/whisper-large-v3-turbo"
llm_model="Qwen/Qwen3.5-9B"
api_base="https://api.deepinfra.com"

state_file="${XDG_RUNTIME_DIR:-/tmp}/transcript.state"
token_file="$HOME/.config/transcript/token"
recording_info="/tmp/recording_info"

auth_token=""
clean_level="light"
srt_flag=0
input_file=""
temp_files=()

usage() {
    cat <<'EOF'
transcript - dictation and file transcription via DeepInfra

Usage:
  transcript [--clean light|full|raw]     toggle push-to-talk dictation
  transcript FILE [--srt]                 write FILE.txt (and FILE.srt)

Options:
  --clean light   fix punctuation/misrecognitions, remove artifacts (default)
  --clean full    light + reformat into paragraphs/lists
  --clean raw     skip the LLM pass (shorthand: --raw)
  --srt           with FILE: also write subtitles
  -h, --help      show this help
EOF
}

set_state() {
    printf '%s' "$1" > "$state_file"
}

notify_error() {
    dunstify -u critical "Whisper Transcript" "$1" 2>/dev/null || true
    set_state error
}

register_temp() {
    temp_files+=("$1")
}

cleanup_temps() {
    local f
    for f in "${temp_files[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}

check_dependencies() {
    local dependency
    for dependency in "${dependencies[@]}"; do
        if ! command -v "$dependency" &>/dev/null; then
            echo "Error: '$dependency' command not found. Please install the corresponding package." >&2
            exit 1
        fi
    done
}

load_token() {
    if [[ -n "${DEEPINFRA_API_TOKEN:-}" ]]; then
        printf '%s' "$DEEPINFRA_API_TOKEN"
    elif [[ -r "$token_file" ]]; then
        head -n 1 "$token_file" | tr -d '[:space:]'
    else
        return 1
    fi
}

api_call() {
    # api_call DESCRIPTION CURL_ARGS...
    # Performs the HTTP request; retries on transport failure or HTTP >= 400
    # (3 attempts, 2s/4s backoff). Prints the response body on 2xx.
    local description="$1"
    shift
    local attempt response http_code
    for attempt in 1 2 3; do
        response=$(curl -sS --max-time 120 -w $'\n%{http_code}' "$@" 2>/dev/null) || response=""
        http_code="${response##*$'\n'}"
        if [[ "$http_code" =~ ^2 ]]; then
            printf '%s' "${response%$'\n'*}"
            return 0
        fi
        [[ "$attempt" -lt 3 ]] && sleep $((attempt * 2))
    done
    echo "Error: API call failed after 3 attempts ($description, status: ${http_code:-no response})" >&2
    return 1
}

start_recording() {
    set_state recording
    local notify_pid tempfile record_pid
    notify_pid=$(dunstify -p -t 0 -u normal "Whisper Transcript" "Recording started..." || true)
    # Sweep wavs orphaned by crashed sessions; /tmp/recording_info is the
    # single-recording lock, so no live recording can match here.
    rm -f /tmp/recording_*.wav
    tempfile=$(mktemp /tmp/recording_XXXXXX.wav)
    arecord -f cd "$tempfile" >/dev/null 2>&1 &
    record_pid=$!
    echo "$record_pid $notify_pid $tempfile" > "$recording_info"
}

stop_recording() {
    local record_pid notify_pid tempfile
    read -r record_pid notify_pid tempfile < "$recording_info"
    register_temp "$tempfile"

    kill -INT "$record_pid" 2>/dev/null || kill "$record_pid" 2>/dev/null || true
    sleep 0.3
    set_state transcribing
    dunstify -t 0 -r "$notify_pid" "Whisper Transcript" "Recording stopped, transcribing..." || true

    local processed_audio text
    if ! processed_audio=$(prepare_audio "$tempfile"); then
        rm -f "$recording_info"
        set_state idle
        return 0
    fi

    if ! text=$(transcribe_audio "$processed_audio" | format_txt) || [[ -z "$text" ]]; then
        notify_error "Transcription failed"
        rm -f "$recording_info"
        return 1
    fi

    if [[ "$clean_level" != "raw" ]]; then
        text=$(printf '%s' "$text" | llm_clean "$clean_level")
    fi

    printf '%s' "$text" | wl-copy || true
    wtype -- "$text" || true
    dunstify -r "$notify_pid" "Whisper Transcript" "Transcript complete" || true

    rm -f "$recording_info"
    set_state idle
}

# Silence-removes the recording and returns the AAC path ready for upload.
prepare_audio() {
    local tempfile="$1"
    local trimmed_audio
    trimmed_audio=$(mktemp /tmp/trimmed_XXXXXX.wav)
    register_temp "$trimmed_audio"

    sox "$tempfile" "$trimmed_audio" silence 1 0.1 0.1% -1 0.1 0.1% 2>/dev/null || true

    # Less than ~1s of audio left (CD wav = 44100 bytes/s) means no speech.
    if [[ ! -s "$trimmed_audio" ]] || [[ "$(stat -c%s "$trimmed_audio")" -lt 44100 ]]; then
        dunstify -u normal "Whisper Transcript" "No speech detected" || true
        return 1
    fi

    convert_to_aac "$trimmed_audio"
}

# Processes an audio/video file: writes <name>.txt (and <name>.srt).
process_file() {
    local path="${1%.*}"
    local audio_file json_result
    audio_file=$(convert_to_aac "$1") || exit 1
    if ! json_result=$(transcribe_audio "$audio_file"); then
        echo "Error: transcription failed for '$1'" >&2
        exit 1
    fi
    printf '%s' "$json_result" | format_txt > "${path}.txt"
    if [[ "$srt_flag" -eq 1 ]]; then
        printf '%s' "$json_result" | format_srt > "${path}.srt"
    fi
    return 0
}

convert_to_aac() {
    local tmp_audio
    tmp_audio=$(mktemp /tmp/"$(basename "$1" .wav)"_XXXXXX.aac)
    register_temp "$tmp_audio"
    ffmpeg -y -i "$1" -vn -c:a aac -ar 44100 -ac 2 "$tmp_audio" >/dev/null 2>&1 || {
        echo "Error: Unable to convert file to AAC format." >&2
        return 1
    }
    printf '%s\n' "$tmp_audio"
}

# Transcribes an AAC file with whisper via the DeepInfra inference API.
transcribe_audio() {
    api_call "whisper inference" \
        -X POST \
        -H "Authorization: Bearer ${auth_token}" \
        -F "audio=@$1" \
        "${api_base}/v1/inference/${inference_model}"
}

# llm_clean LEVEL - cleans the transcript from stdin, prints cleaned text.
# Dictation must never hard-fail on the optional stage: falls back to input.
llm_clean() {
    local level="$1"
    local input prompt response cleaned
    input=$(cat)
    [[ -z "${input//[[:space:]]/}" ]] && { printf '%s' "$input"; return 0; }

    case "$level" in
        light)
            prompt="You are a post-processor for speech-to-text output. Respond with ONLY the corrected text itself: no preamble, no quotes, no explanations. Correct misrecognized words and punctuation and remove phantom filler artifacts such as stray acknowledgements. Keep the wording and language exactly as spoken. Do not summarize, translate, or reformat."
            ;;
        full)
            prompt="You are a post-processor for speech-to-text output. Respond with ONLY the cleaned text itself: no preamble, no quotes, no explanations. Correct misrecognized words and punctuation, remove phantom filler artifacts, and structure the text with paragraphs and lists where the content calls for it. Keep the language and the spoken meaning. Do not summarize or translate."
            ;;
    esac

    # chat_template_kwargs disables Qwen3.5 thinking mode — otherwise the
    # answer lands in reasoning_content and .content comes back empty.
    if ! response=$(api_call "llm cleanup" \
        -X POST \
        -H "Authorization: Bearer ${auth_token}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg model "$llm_model" --arg prompt "$prompt" --arg text "$input" \
            '{model: $model, temperature: 0, max_tokens: 2048,
              chat_template_kwargs: {enable_thinking: false},
              messages: [{role: "system", content: $prompt},
                         {role: "user", content: $text}]}')" \
        "${api_base}/v1/openai/chat/completions"); then
        printf '%s' "$input"
        return 0
    fi

    if ! cleaned=$(printf '%s' "$response" | jq -er '.choices[0].message.content // empty' 2>/dev/null) || [[ -z "$cleaned" ]]; then
        cleaned="$input"
    fi
    printf '%s' "$cleaned"
}

# Format transcribed text for plain text output
format_txt() {
    jq -r '.text | gsub("^ +";"")'
}

# Format transcribed text into SRT subtitle format
format_srt() {
    jq -r '
.segments[] |
   .start as $start |
    ($start | tostring | split(".")) as $split |
    (
        ($split[0] | tonumber | strftime("%H:%M:%S")) +
        "." +
        ($split[1] |.[0:3])
    ) as $start_formatted |
   .end as $end |
    ($end | tostring | split(".")) as $split |
    (
        ($split[0] | tonumber | strftime("%H:%M:%S")) +
        "." +
        ($split[1] |.[0:3])
    ) as $end_formatted |
   "\(.id)\n\($start_formatted) --> \($end_formatted)\n\(.text | gsub("^ +";"") | gsub(" +$";""))\n"
  '
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean)
                [[ $# -ge 2 ]] || { echo "Error: --clean requires a value (light|full|raw)" >&2; exit 1; }
                clean_level="$2"
                shift 2
                ;;
            --clean=*)
                clean_level="${1#*=}"
                shift
                ;;
            --raw)
                clean_level="raw"
                shift
                ;;
            --srt)
                srt_flag=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                if [[ -n "$input_file" ]]; then
                    echo "Error: unexpected argument '$1'" >&2
                    exit 1
                fi
                input_file="$1"
                shift
                ;;
        esac
    done
    if [[ ! "$clean_level" =~ ^(light|full|raw)$ ]]; then
        echo "Error: --clean must be light, full, or raw" >&2
        exit 1
    fi
}

# Main script logic: starts/stops recording or processes a file
main() {
    parse_args "$@"
    check_dependencies

    if ! auth_token=$(load_token); then
        notify_error "No API token found (set DEEPINFRA_API_TOKEN or create $token_file)"
        exit 1
    fi

    if [[ -n "$input_file" ]]; then
        process_file "$input_file"
        return
    fi

    if [[ -f "$recording_info" ]]; then
        local record_pid notify_pid tempfile
        read -r record_pid notify_pid tempfile < "$recording_info"
        if ps -p "$record_pid" >/dev/null; then
            stop_recording
        else
            start_recording
        fi
    else
        start_recording
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap cleanup_temps EXIT
    main "$@"
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/transcript/run_tests.sh`
Expected: `ok -` for every assertion, ending with `All tests passed.` and exit code 0.

- [ ] **Step 5: Lint both shell files**

Run: `shellcheck roles/system/core/files/usr/bin/transcript tests/transcript/run_tests.sh`
Expected: no output (exit 0). Fix any warning before committing.

- [ ] **Step 6: Commit**

```bash
git add roles/system/core/files/usr/bin/transcript tests/transcript/run_tests.sh
git commit -m "feat(system/core): rewrite transcript with curl API, retries, LLM cleanup, wayland paste"
```

---

### Task 2: Verify live LLM model id and endpoints, set up host token

**Files:**
- Modify (only if the default model id is wrong): `roles/system/core/files/usr/bin/transcript` (the `llm_model=` line)
- Create (host, not committed): `~/.config/transcript/token`

**Interfaces:**
- Consumes: `llm_model` constant and `${api_base}/v1/openai/chat/completions` endpoint from Task 1.
- Produces: a verified `llm_model` value for Task 4's live smoke test; host token file read by `load_token`.

VERIFIED DURING PLAN SELF-REVIEW (2026-08-19, live against the API):
- `Qwen/Qwen3.5-9B` exists on DeepInfra and, with `"chat_template_kwargs":{"enable_thinking":false}`, returns clean corrected text in `.choices[0].message.content`. Without that flag the answer goes to `reasoning_content` and `content` is empty.
- `Qwen/Qwen2.5-7B-Instruct` does NOT exist anymore; `meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo` exists but ignored correction instructions.
- Whisper endpoint accepts multipart `audio=@file` and returns `text` + `segments` (jq filters' contract holds).
- The host token file `~/.config/transcript/token` (32 chars, mode 600) was already created from the user-provided token.

NOTE: this task touches a secret. The DeepInfra token must never be printed to a committed file or echoed in full.

- [ ] **Step 1: Verify the host token file**

Run: `stat -c '%a %s' ~/.config/transcript/token`
Expected: `600 32` (created during plan self-review). If missing, recreate it from the user-provided token (never commit it): `install -d -m 700 ~/.config/transcript && umask 077 && printf '%s' '<chat-token>' > ~/.config/transcript/token`

- [ ] **Step 2: Confirm the model id is still listed**

Run:

```bash
source_token=$(cat ~/.config/transcript/token)
curl -sS --max-time 30 -H "Authorization: Bearer ${source_token}" \
    https://api.deepinfra.com/v1/openai/models | jq -r '.data[].id' | grep -x 'Qwen/Qwen3.5-9B'
```

Expected: `Qwen/Qwen3.5-9B`. If empty (model retired since verification), list candidates with `grep -iE 'qwen'`, pick the closest small non-thinking-capable instruct model, and edit the `llm_model=` line in `roles/system/core/files/usr/bin/transcript` to that exact id.

- [ ] **Step 3: Smoke-test the chat completions endpoint with the script's exact payload shape**

Run:

```bash
source_token=$(cat ~/.config/transcript/token)
curl -sS --max-time 60 -H "Authorization: Bearer ${source_token}" -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen3.5-9B","temperature":0,"max_tokens":2048,"chat_template_kwargs":{"enable_thinking":false},"messages":[{"role":"system","content":"You are a post-processor for speech-to-text output. Respond with ONLY the corrected text itself: no preamble, no quotes, no explanations. Correct misrecognized words and punctuation and remove phantom filler artifacts such as stray acknowledgements. Keep the wording and language exactly as spoken. Do not summarize, translate, or reformat."},{"role":"user","content":"so yeah... thank you. i think we shoudl use the terminal to instal the packeges"}]}' \
    https://api.deepinfra.com/v1/openai/chat/completions | jq -r '.choices[0].message.content'
```

Expected: corrected text like `So yeah... I think we should use the terminal to install the packages.` — typos fixed, no preamble/quotes. (Keeping or dropping "thank you" is ambiguous here; the real phantom-word case is silence-induced and the prompt targets it.)

- [ ] **Step 4: Re-run unit tests and commit if the model id changed**

Run: `bash tests/transcript/run_tests.sh`
Expected: `All tests passed.`

If `llm_model` was edited:

```bash
git add roles/system/core/files/usr/bin/transcript
git commit -m "fix(system/core): transcript use verified DeepInfra LLM model id"
```

If unchanged, no commit.

- [ ] **Step 5: Re-run unit tests and commit if the model id changed**

Run: `bash tests/transcript/run_tests.sh`
Expected: `All tests passed.`

If `llm_model` was edited:

```bash
git add roles/system/core/files/usr/bin/transcript
git commit -m "fix(system/core): transcript use verified DeepInfra LLM model id"
```

If unchanged, no commit.

---

### Task 3: Waybar pulsing pill (module script, config, CSS)

**Files:**
- Create: `roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh`
- Modify: `roles/desktop/waybar/templates/home/.config/waybar/config.j2:25` (modules-right) and after line 42 (module definition)
- Modify: `roles/desktop/waybar/files/home/.config/waybar/style.css` (append after the `#custom-voxtype` block, reuses the existing `pulse` keyframes at line 236)
- Modify: `roles/desktop/waybar/tasks/main.yml` (append a copy task for the module script after the clock-script task — the role deploys scripts per-file)

**Interfaces:**
- Consumes: state file `$XDG_RUNTIME_DIR/transcript.state` with values `idle|recording|transcribing|error` (contract from Task 1).
- Produces: waybar module `custom/transcript` emitting `{"text": "<icon>", "class": "<state>"}` with classes `idle|recording|transcribing|error` (styled in this task's CSS).

- [ ] **Step 1: Write the module script**

Create `roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh`:

```bash
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
```

- [ ] **Step 2: Test the module script standalone**

Run:

```bash
bash roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh
printf 'recording' > "${XDG_RUNTIME_DIR:-/tmp}/transcript.state"
bash roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh
printf 'transcribing' > "${XDG_RUNTIME_DIR:-/tmp}/transcript.state"
bash roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh
rm -f "${XDG_RUNTIME_DIR:-/tmp}/transcript.state"
```

Expected output, in order:
`{"text": "🎙️", "class": "idle"}` (or the stale state file's value if one exists)
`{"text": "🎤", "class": "recording"}`
`{"text": "⏳", "class": "transcribing"}`

- [ ] **Step 3: Lint the module script**

Run: `shellcheck roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh`
Expected: no output (exit 0).

- [ ] **Step 4: Register the module in the waybar config template**

In `roles/desktop/waybar/templates/home/.config/waybar/config.j2`, add the module to `modules-right` so it sits left of the voxtype module (around line 25):

```json
        "custom/transcript",
        "custom/voxtype",
```

(old: only the `"custom/voxtype",` line)

Then add the module definition immediately after the `"custom/voxtype": { ... },` block (after line 42):

```json
    "custom/transcript": {
        "exec": "~/.config/waybar/scripts/waybar-transcript.sh",
        "return-type": "json",
        "interval": 1,
        "tooltip": false
    },
```

- [ ] **Step 5: Style the pill**

Append to `roles/desktop/waybar/files/home/.config/waybar/style.css` (after the `@keyframes pulse` block; reuses that keyframes and the `#clock` pill palette):

```css
#custom-transcript {
    padding: 0 8px;
    font-size: 14px;
    border-radius: 12px;
    background: linear-gradient(45deg, rgba(40, 50, 75, 0.8), rgba(60, 70, 90, 0.8));
    border: 1px solid rgba(255, 255, 255, 0.1);
}

#custom-transcript.recording {
    color: #ff5555;
    animation: pulse 1s infinite;
}

#custom-transcript.transcribing {
    color: #f1fa8c;
}

#custom-transcript.error {
    color: #ff5555;
    background: rgba(255, 85, 85, 0.25);
}
```

- [ ] **Step 6: Syntax-check the playbook**

Run: `uv run ansible-playbook playbook.yml --vault-password-file password.sh --syntax-check`
Expected: `playbook: playbook.yml` with no errors (confirms the edited `.j2` didn't break anything loadable).

- [ ] **Step 6b: Wire the module script into the role's deploy tasks**

Append to `roles/desktop/waybar/tasks/main.yml`, immediately after the "Copy Waybar clock script" task, mirroring it exactly:

```yaml
- name: Copy Waybar transcript script
  ansible.builtin.copy:
    src: files/home/.config/waybar/scripts/waybar-transcript.sh
    dest: "{{ ansible_facts['user_dir'] }}/.config/waybar/scripts/waybar-transcript.sh"
    mode: '0755'
  tags: [desktop, waybar, config]
```

Verify: `uv run ansible-lint roles/desktop/waybar/` (clean) and a check-mode run of the role via a scoped /tmp playbook (see Task 4 Step 3) showing the new task as `changed`.

NOTE (discovered during execution): `--tags waybar` from `playbook.yml` does NOT reach the role — the meta-role `include_role` is tagged `[desktop]` only, so the include is skipped for any other tag. Scoped deploys must use a /tmp playbook that imports the role directly.

- [ ] **Step 7: Commit**

```bash
git add roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh \
        roles/desktop/waybar/templates/home/.config/waybar/config.j2 \
        roles/desktop/waybar/files/home/.config/waybar/style.css
git commit -m "feat(desktop/waybar): add transcript state pill module with recording pulse"
```

---

### Task 4: Deploy to host and run end-to-end smoke tests

**Files:**
- Modify (host, not the repo): `/usr/bin/transcript`, `~/.config/waybar/{config,style.css,scripts/waybar-transcript.sh}`

**Interfaces:**
- Consumes: all prior tasks (script, token, waybar pieces).
- Produces: a working dictation setup on this machine (inventory `localhost`, user `michel`), plus a manual validation checklist for the user.

- [ ] **Step 1: Verify runtime dependencies exist on the host**

Run: `for c in arecord curl jq wl-copy wtype dunstify sox ffmpeg; do command -v "$c" >/dev/null || echo "MISSING: $c"; done`
Expected: no output (`wl-copy`/`wtype` come from the voxtype role's pacman packages). If anything is missing, install it with `sudo pacman -S wl-clipboard wtype` etc. before continuing.

- [ ] **Step 2: Install the script to /usr/bin**

Run: `sudo -n install -m 0755 roles/system/core/files/usr/bin/transcript /usr/bin/transcript 2>/dev/null || sudo install -m 0755 roles/system/core/files/usr/bin/transcript /usr/bin/transcript`
Expected: no error. If sudo cannot get a password non-interactively in this environment, stop and ask the user to run the `sudo install` command themselves.

- [ ] **Step 3: Deploy the waybar pieces via a scoped playbook**

`--tags waybar` cannot reach the role through the meta-role (its `include_role` is tagged `[desktop]` only — see Task 3 Step 6b note). Use a scoped playbook instead. Create `/tmp/waybar-deploy.yml`:

```yaml
---
- name: Scoped deploy of desktop/waybar
  hosts: localhost
  connection: local
  gather_facts: true
  vars_files:
    - /mnt/POOL_1_DATA/CONFIGURATION/DotArch/group_vars/all/variables.yml
    - /mnt/POOL_1_DATA/CONFIGURATION/DotArch/group_vars/all/deployment_config.yml
  roles:
    - role: /mnt/POOL_1_DATA/CONFIGURATION/DotArch/roles/desktop/waybar
```

Run (battery detection mirrors `playbook.yml`'s pre_task; `--skip-tags package` skips only the become+pacman task, which fails on this host's root-squashed NFS and is unnecessary — waybar is already installed):

```bash
uv run ansible-playbook /tmp/waybar-deploy.yml --vault-password-file password.sh \
    --skip-tags package -e deploy_without_passwords=true \
    -e "target=$(if [ -d /sys/class/power_supply/BAT0 ]; then echo laptop; else echo desktop; fi)"
```

Expected: the "Template Waybar config", "Copy Waybar configuration" (style.css), and "Copy Waybar transcript script" tasks report `changed`; no failures. This deploys to `~/.config/waybar/` for user michel on localhost. IMPORTANT: `target` must be `laptop` on battery-equipped machines or the rendered config loses the battery/backlight modules.

- [ ] **Step 4: Reload waybar**

Run: `pkill -SIGUSR2 waybar || true`
Expected: waybar reloads its config. If the pill doesn't appear within a few seconds, fall back to a full restart: `pkill waybar; sleep 1; hyprctl dispatch exec waybar`.

- [ ] **Step 5: Smoke-test file mode end-to-end (whisper + retry layer live)**

Run:

```bash
ffmpeg -y -f lavfi -i 'sine=frequency=440:duration=1' /tmp/transcript_smoke.wav >/dev/null 2>&1
transcript /tmp/transcript_smoke.wav
ls -la /tmp/transcript_smoke.txt && head -c 200 /tmp/transcript_smoke.txt; echo
```

Expected: `/tmp/transcript_smoke.txt` exists (likely near-empty for a sine tone — the point is HTTP 200 through the script's API layer, no `deepctl`). Then clean up: `rm -f /tmp/transcript_smoke.wav /tmp/transcript_smoke.txt /tmp/transcript_probe.wav`

- [ ] **Step 6: Smoke-test the dictation toggle + state file**

Run:

```bash
transcript
sleep 1
cat "${XDG_RUNTIME_DIR:-/tmp}/transcript.state"; echo
transcript
sleep 5
cat "${XDG_RUNTIME_DIR:-/tmp}/transcript.state"; echo
```

The first call starts `arecord` in the background and exits; the second call stops it (the toggle reads `/tmp/recording_info` and checks the recorder pid — do NOT kill arecord manually between calls or the toggle would start a new recording instead of stopping).

Expected: first state read shows `recording`; after the second toggle (which stops and transcribes ~1s of ambient noise) the state becomes `idle` — either via the "No speech detected" dunstify path or a completed transcription. The waybar pill should have pulsed 🎤 then returned to idle 🎙️.

- [ ] **Step 7: Verify --help and cleanup**

Run: `transcript --help`
Expected: the usage text from Task 1.

- [ ] **Step 8: Hand the manual validation checklist to the user**

No command — report this checklist to the user as the deliverable:

1. Dictate with `transcript` (run from a terminal, or bind a temporary key yourself — `Super+A` stays voxtype's): speak normally but include deliberate 2-3s thinking pauses. Confirm pauses don't produce punctuation/phantom words.
2. Compare cleanup levels on similar dictations: default (`light`), `--clean full` (lists/paragraphs), `--raw` (untouched whisper output).
3. Watch the waybar pill: pulse while recording, ⏳ while transcribing, back to idle.
4. After ~10 minutes idle, dictate again — the retry layer should absorb the DeepInfra cold-start (historically the "fails the first time" issue). Check for a dunstify "Transcript complete" without errors.
5. File mode on real content: `transcript some_video.mp4 --srt` produces `.txt` + `.srt` next to the file.

After validation, the user decides on the voxtype replacement (separate later phase per spec).
