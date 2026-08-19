# Transcript Script Restoration — Design

Date: 2026-08-19
Status: Approved (approach A)

## Context

The push-to-talk dictation tool `/usr/bin/transcript` (deployed from
`roles/system/core/files/usr/bin/transcript`) is dead in practice: its only
transcription backend is `deepctl`, the abandoned DeepInfra CLI. The user
currently dictates with VoxType instead, but VoxType does not skip silence in
recordings, so thinking pauses produce bad punctuation and phantom words
(e.g. "thank you"). The old script's sox silence-removal stage solves exactly
that, which motivates restoring it with a modern API layer.

## Goals

- Restore `transcript` as a working dictation tool, replacing `deepctl` with
  direct curl calls to DeepInfra.
- Keep silence-removal; remove the `tempo 1.2` audio speedup (suspected
  quality cost, no benefit).
- Add an optional LLM cleanup pass with two levels (light correction, full
  formatting), always-on light for now — the user will A/B test which to keep.
- Make every API call resilient: retry with backoff (the first call after
  idle historically failed — DeepInfra model cold-start).
- Replace X11 paste tools (`xclip`, `xdotool`) with Wayland equivalents
  (`wl-copy`, `wtype`).
- Add a waybar "pill" module with a CSS pulse animation while recording.
- Deploy to the host for manual testing and validation. VoxType stays
  installed and bound during this phase.

## Non-goals (this phase)

- Removing or gating the VoxType role — decided after validation.
- Ansible vault templating of the token (manual token file during test).
- Changing file/SRT transcription behavior (only the backend call changes).

## Approach

Extend the existing single-file bash script (approach A). New stages are
added as functions; no pipeline split, no rewrite. Matches the repo's
`files/usr/bin/*` static-script pattern.

## Pipeline

Toggle mode (no arguments):

1. `start_recording` — `arecord -f cd` to a temp wav (unchanged).
2. `stop_recording` — kill recorder, then:
3. `prepare_audio` — sox **silence removal only** (existing parameters);
   the `tempo 1.2` step is removed.
4. `convert_to_aac` — ffmpeg to AAC (kept: compresses upload).
5. `transcribe_audio` — curl to DeepInfra whisper (see API layer).
6. `llm_clean` — optional second pass (see LLM layers).
7. `format_txt` (existing jq) → `wl-copy`, then `wtype` to paste.
8. Cleanup of temp files.

File mode (`transcript FILE [--srt]`): unchanged behavior, but the backend
call goes through the new API layer. The LLM pass never applies to SRT output
(it would destroy timestamps); for plain `.txt` file output it stays off too —
LLM cleanup is a dictation-mode feature.

## API layer

Both whisper and LLM calls share one function performing the HTTP request
with retry:

- Up to 3 attempts, 2s / 4s backoff between attempts.
- Retry on: curl transport failure, timeout, HTTP non-200.
- Whisper endpoint:
  `POST https://api.deepinfra.com/v1/inference/openai/whisper-large-v3-turbo`
  with `Authorization: Bearer <token>` and multipart `audio=@<file>`.
  Response JSON is identical to what `deepctl` returned, so the existing
  `format_txt` / `format_srt` jq filters are unchanged.
- LLM endpoint (OpenAI-compatible chat completions on DeepInfra):
  `POST https://api.deepinfra.com/v1/openai/chat/completions`.
- Model: a small instruct model (e.g. Qwen3-8B class). The exact model id
  must be verified against the live API model list during implementation.

### Token handling

- Script reads the token from `$DEEPINFRA_API_TOKEN`, falling back to
  `~/.config/transcript/token` (mode 600).
- The token is never embedded in the script itself (it lives world-readable
  in `/usr/bin`).
- During the test phase the token file is created manually on the host.
  Later Ansible integration will template it from vault (same pattern as
  `roles/apps/voxtype/vars/secret.yml`).

## LLM cleanup layers

Selected by flag; default `light`:

- `--clean light` (default): fix misrecognitions and punctuation, remove
  phantom/filler artifacts, keep wording verbatim, same language.
- `--clean full`: light + restructure into paragraphs/lists when content
  calls for it.
- `--raw`: skip the LLM pass entirely.

Prompts instruct the model to output plain text only, no commentary. On LLM
failure after retries, fall back to the raw whisper text (dictation should
never hard-fail because of the optional stage).

## Wayland paste

- `wl-copy` replaces `xclip`.
- `wtype` replaces `xdotool key ctrl+shift+v` (types the text directly, same
  mechanism VoxType uses).
- Dependency list updated accordingly: drop `deepctl`, `xclip`, `xdotool`;
  add `wl-clipboard`, `wtype`; keep `arecord`, `sox`, `ffmpeg`, `jq`,
  `dunstify`.

## Waybar integration

- The script writes its state to `$XDG_RUNTIME_DIR/transcript.state`:
  `idle | recording | transcribing | error`.
- New waybar module `custom/transcript` runs a small script
  (`waybar-transcript.sh`, 1s interval) that reads the state file and emits
  JSON with icon text and a CSS class matching the state.
- `style.css`: pill background; `@keyframes` pulse animation on
  `#custom-transcript.recording`; distinct color for `.transcribing`; red for
  `.error`.

## Error handling

- Any final failure after retries (dictation mode): `dunstify` error
  notification, state set to `error`, temp files cleaned.
- Missing token / missing dependencies: immediate error notification
  (dependency check retained from current script).

## Deployment (test phase)

Host-side only, VoxType untouched:

1. Copy the updated script to `/usr/bin/transcript`.
2. Create `~/.config/transcript/token` (600) with the DeepInfra token.
3. Add the waybar module + module script + CSS on the host.
4. Optional temporary keybind for testing (e.g. `Super+Shift+A`); `Super+A`
   remains VoxType's toggle.

Repo files are updated in parallel so they stay the source of truth for the
later integration phase.

## Risks / open items

- `arecord` on PipeWire: worked historically; if the default device
  misbehaves during testing, switch to `pw-record` (drop-in in the recording
  function).
- Exact DeepInfra LLM model id to be confirmed against the live model list.
- sox silence-removal parameters are kept as-is; fine-tuning (thresholds,
  whether internal pauses collapse) is a testing-phase activity.

## Later phase (out of scope here)

After validation: decide VoxType replacement; if adopted, gate voxtype behind
`enable_voxtype`, rebind `Super+A` to `transcript`, template the token from
`vault_deepinfra_api_token`, and swap the waybar module.
