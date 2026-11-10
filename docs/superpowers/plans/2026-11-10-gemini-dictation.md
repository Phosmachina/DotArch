# Migration dictée → Gemini 3.5 Transcribe — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** remplacer la chaîne dictée ASR-DeepInfra + cleanup-LLM du script `transcript` par un unique appel Gemini 3.5 Transcribe (mode smart par défaut, verbatim avec `--raw`), avec vocabulaire custom.

**Architecture :** le script bash `transcript` garde son flux (arecord → sox → FLAC → API → paste) ; seule la fonction de transcription dictée change (`transcribe_dictation` via l'API Interactions de Google, audio inline base64). Le mode fichier (whisper/DeepInfra) et la plomberie de jobs/paste restent intacts. Spec : `docs/superpowers/specs/2026-11-10-gemini-dictation-design.md`.

**Tech Stack :** bash, curl, jq, base64 (coreutils) — aucune nouvelle dépendance. API : `POST https://generativelanguage.googleapis.com/v1beta/interactions`, clé via `x-goog-api-key`.

## Global Constraints

- **Jamais de secret dans le dépôt** : la clé Gemini vit uniquement sur l'hôte (`~/.config/transcript/gemini_key`, perms 600) ou en env `GEMINI_API_KEY`. Ne jamais l'écrire dans un fichier commité (le pre-commit `encrypt.sh` ne couvre que `group_vars`).
- **Commits chirurgicaux** : le dépôt contient des modifications non commitées appartenant à l'utilisateur (`inventory.ini`, `roles/system/core/tasks/*`, `vault.yml`, fichiers non suivis). `git add` uniquement les fichiers listés par chaque tâche — jamais `git add -A`.
- **Style** : suivre le style du fichier existant (bash, indentation 4 espaces, commentaires anglais). Messages de commit `feat(transcript): …` / `fix(transcript): …` / `feat(waybar): …`.
- **Tests** : `bash tests/transcript/run_tests.sh` doit être vert avant chaque commit qui touche `transcript` ou son harness.
- **API déjà vérifiée en live** (2026-11-10) : inline FLAC OK, smart/verbatim OK, jq `[.steps[].content[]?.text // empty] | join("")` OK, vocabulaire custom indispensable dans les DEUX modes, ~2,9 s / ~0,001 $ par dictée, HTTP 402 = crédits prépayés épuisés.
- Fichier sous test : `roles/system/core/files/usr/bin/transcript` (copie du dépôt — l'installé `/usr/bin/transcript` diffère : il a `whisper-large-v3-turbo` en dictée ; on n'édite PAS /usr/bin pendant les tâches 1–5, déploiement en tâche 6).
- Les numéros de ligne ci-dessous font référence à l'état actuel du fichier du dépôt ; en cas de dérive, localiser par symbole.

---

### Task 1: `api_call` — message d'erreur explicite sur HTTP 402

**Files:**
- Modify: `roles/system/core/files/usr/bin/transcript:130-148` (fonction `api_call`)
- Test: `tests/transcript/run_tests.sh` (insertion après le bloc « api_call: gives up after exactly 3 attempts », ~ligne 77)

**Interfaces:**
- Consumes: rien de nouveau.
- Produces: `api_call` inchangée en signature (description + args curl → body sur stdout, exit ≠ 0 sur échec) ; seul le message d'erreur final mentionne le 402. Les tâches 3–6 dépendent de ce comportement.

- [ ] **Step 1: écrire le test en échec**

Dans `tests/transcript/run_tests.sh`, après le bloc « gives up after exactly 3 attempts » (après la ligne `assert_eq "$curl_calls" "3" "api_call makes exactly 3 attempts"`), ajouter :

```bash

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
```

- [ ] **Step 2: vérifier l'échec**

Run: `bash tests/transcript/run_tests.sh`
Expected: `FAIL - 402 error must hint at topping up the balance` (l'échec existe déjà sur « must fail on persistent 402 » ? Non — l'api_call actuelle échoue bien, seul le message manque ; le FAIL attendu est celui du hint).

- [ ] **Step 3: implémenter**

Dans `api_call` (le `echo "Error: ..."` final), remplacer :

```bash
    echo "Error: API call failed after 3 attempts ($description, status: ${http_code:-no response})" >&2
    return 1
```

par :

```bash
    if [[ "$http_code" == "402" ]]; then
        echo "Error: API call failed after 3 attempts ($description, HTTP 402 — prepaid balance depleted, top up the provider account)" >&2
    else
        echo "Error: API call failed after 3 attempts ($description, status: ${http_code:-no response})" >&2
    fi
    return 1
```

- [ ] **Step 4: vérifier le passage**

Run: `bash tests/transcript/run_tests.sh`
Expected: `All tests passed.`

- [ ] **Step 5: commit**

```bash
git add roles/system/core/files/usr/bin/transcript tests/transcript/run_tests.sh
git commit -m "feat(transcript): explicit top-up hint on HTTP 402"
```

---

### Task 2: `load_gemini_key` + `emit_vocabulary`

**Files:**
- Modify: `roles/system/core/files/usr/bin/transcript` — bloc de config (~lignes 13-28) et nouvelles fonctions après `load_token` (~ligne 128)
- Test: `tests/transcript/run_tests.sh` (insertion après les tests `load_token`, ~ligne 179)

**Interfaces:**
- Consumes: `jq`, `grep`.
- Produces:
  - `gemini_model="models/gemini-3.5-transcribe"`, `gemini_api_base="https://generativelanguage.googleapis.com"`, `gemini_key_file`, `vocabulary_file`, `gemini_key=""` (globales)
  - `load_gemini_key` → stdout la clé (env `GEMINI_API_KEY` prioritaire, sinon 1re ligne du fichier), exit 1 si introuvable
  - `emit_vocabulary` → stdout un tableau JSON compact (`["a","b"]`) ou rien (exit 0) si fichier absent/vide

- [ ] **Step 1: écrire les tests en échec**

Dans `tests/transcript/run_tests.sh`, après le bloc `load_token` (après `export DEEPINFRA_API_TOKEN="test-token"`), ajouter :

```bash

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
```

- [ ] **Step 2: vérifier l'échec**

Run: `bash tests/transcript/run_tests.sh`
Expected: FAIL `load_gemini_key: command not found` (le sourcing du script échoue silencieusement sur les appels — les asserts échouent avec vide).

- [ ] **Step 3: implémenter (additions pures — les variables mortes partent en Task 4)**

Dans le bloc de config du script, ajouter après les variables existantes (sans rien supprimer à ce stade) :

```bash
# Dictation: one Gemini call — smart mode rewrites (fillers dropped,
# self-corrections folded, punctuation) like Gboard's dictation; --raw picks
# verbatim. Language auto-detects with FR/EN code-switching.
gemini_model="models/gemini-3.5-transcribe"
gemini_api_base="https://generativelanguage.googleapis.com"
gemini_key=""
```

Puis, juste après la fonction `load_token`, ajouter :

```bash
load_gemini_key() {
    if [[ -n "${GEMINI_API_KEY:-}" ]]; then
        printf '%s' "$GEMINI_API_KEY"
    elif [[ -r "$gemini_key_file" ]]; then
        head -n 1 "$gemini_key_file" | tr -d '[:space:]'
    else
        return 1
    fi
}

# Emits the custom_vocabulary JSON array from $vocabulary_file (one term per
# line; blank lines and # comments skipped; capped at 1000 per the API), or
# nothing when there is nothing to send. Sent in BOTH smart and verbatim
# modes — the live smoke test showed jargon degrades badly without it
# ("hyprland et waybar sur archlinux" heard as "le Wi-Fi sur un Linux").
emit_vocabulary() {
    [[ -r "$vocabulary_file" ]] || return 0
    local terms
    terms=$(grep -vE '^[[:space:]]*(#|$)' "$vocabulary_file" | head -1000)
    [[ -z "$terms" ]] && return 0
    printf '%s\n' "$terms" | jq -Rsc 'split("\n") | map(select(length > 0))'
}
```

Et dans le bloc des chemins runtime, ajouter à côté de `token_file` :

```bash
gemini_key_file="$HOME/.config/transcript/gemini_key"
vocabulary_file="$HOME/.config/transcript/vocabulary"
```

- [ ] **Step 4: vérifier le passage**

Run: `bash tests/transcript/run_tests.sh`
Expected: `All tests passed.`

- [ ] **Step 5: commit**

```bash
git add roles/system/core/files/usr/bin/transcript tests/transcript/run_tests.sh
git commit -m "feat(transcript): Gemini key loading + custom vocabulary helper"
```

---

### Task 3: `transcribe_dictation`

**Files:**
- Modify: `roles/system/core/files/usr/bin/transcript` — nouvelle fonction après `transcribe_audio` (~ligne 309)
- Test: `tests/transcript/run_tests.sh` (insertion après les tests `format_txt`, ~ligne 99)

**Interfaces:**
- Consumes: `emit_vocabulary` (Task 2), `api_call` (Task 1), `gemini_model`, `gemini_api_base`, `gemini_key`, `clean_level`.
- Produces: `transcribe_dictation FLAC_PATH` → stdout le texte transcrit, exit 1 sur échec API ou texte vide. Consommée par `stop_recording` (Task 4).

- [ ] **Step 1: écrire les tests en échec**

Dans `tests/transcript/run_tests.sh`, après le bloc `format_txt`, ajouter :

```bash

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
rm -f "$fake_flac"
```

- [ ] **Step 2: vérifier l'échec**

Run: `bash tests/transcript/run_tests.sh`
Expected: FAIL `transcribe_dictation: command not found` (asserts vides).

- [ ] **Step 3: implémenter**

Après la fonction `transcribe_audio`, ajouter :

```bash
# Transcribes dictation audio via the Gemini Interactions API — one call
# replacing the old ASR + LLM-cleanup chain. $clean_level drives the mode:
# "raw" -> verbatim (exact words), anything else -> smart (Google's dictation
# rewriting: fillers dropped, self-corrections folded, punctuation and
# formatting applied). Language auto-detects with code-switching; the custom
# vocabulary rides along in both modes. Prints the transcribed text.
transcribe_dictation() {
    local file="$1" b64 mode_json vocab response text
    b64=$(base64 -w0 "$file")

    if [[ "$clean_level" == "raw" ]]; then
        mode_json='{"type": "verbatim"}'
    else
        mode_json='"smart"'
    fi

    vocab=$(emit_vocabulary) || vocab=""
    local vocab_arg="null"
    [[ -n "$vocab" ]] && vocab_arg="$vocab"

    if ! response=$(jq -n --arg model "$gemini_model" --arg b64 "$b64" \
            --argjson mode "$mode_json" --argjson vocab "$vocab_arg" \
            '{model: $model,
              input: [{type: "audio", data: $b64, mime_type: "audio/flac"}],
              generation_config: {transcription_config:
                ({mode: $mode} + (if $vocab then {custom_vocabulary: $vocab} else {} end))
              }}' \
        | api_call "Gemini dictation" \
            -X POST \
            -H "x-goog-api-key: ${gemini_key}" \
            -H "Content-Type: application/json" \
            -d @- \
            "${gemini_api_base}/v1beta/interactions"); then
        return 1
    fi

    # REST responses carry no top-level output_text: text lives in the steps'
    # content parts (extraction path confirmed against the live API).
    text=$(printf '%s' "$response" | jq -r '[.steps[].content[]?.text // empty] | join("")')
    [[ -n "$text" ]] || return 1
    printf '%s' "$text"
}
```

- [ ] **Step 4: vérifier le passage**

Run: `bash tests/transcript/run_tests.sh`
Expected: `All tests passed.`

- [ ] **Step 5: commit**

```bash
git add roles/system/core/files/usr/bin/transcript tests/transcript/run_tests.sh
git commit -m "feat(transcript): single-call Gemini dictation transcription"
```

---

### Task 4: re câblage de la dictée (et suppression de la chaîne DeepInfra-cleanup)

**Files:**
- Modify: `roles/system/core/files/usr/bin/transcript` — `usage` (~40-66), `stop_recording` (~188-203), `transcribe_audio` (~296-309), `process_file` (~273), suppression de `llm_clean` (~311-348), `parse_args` (~383-421), `main` (~424-456), en-tête (~6), runtime vars `last_raw_file` (~40)
- Test: `tests/transcript/run_tests.sh` — suppression des 3 tests `llm_clean` (~79-95), ajustements défaut/parse_args, retrait de `last_raw_file` dans le test stop_recording (~156)

**Interfaces:**
- Consumes: `transcribe_dictation` (Task 3), `load_gemini_key` (Task 2).
- Produces: UX finale — `transcript [--raw]` (défaut smart), `--clean` rejeté, mode fichier inchangé (`transcribe_audio FILE` sans 2e argument).

- [ ] **Step 1: mettre à jour les tests (ils échoueront contre l'ancien code)**

1. Supprimer les trois blocs `llm_clean` (`returns model content`, `falls back to input on API failure`, `passes empty input through`) — `llm_clean` va disparaître.
2. Remplacer le bloc « default clean level » :

```bash
# --- default clean level (script init value, before parse_args mutations) ---
assert_eq "$clean_level" "smart" "default clean level is smart"
```

3. Remplacer le premier bloc `parse_args` (l'ancien appelait `--clean full`) et ajouter le rejet de `--clean` :

```bash
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
```

4. Dans le test `stop_recording`, supprimer les lignes `last_raw_file="$(mktemp)"` et son `rm -f ... "$last_raw_file"` (la variable disparaît du script).

- [ ] **Step 2: vérifier l'échec**

Run: `bash tests/transcript/run_tests.sh`
Expected: FAIL sur `default clean level is smart` (valeur actuelle `full`), FAIL sur `--clean is rejected` (actuellement accepté), et erreurs `llm_clean` si les blocs n'ont pas tous été retirés.

- [ ] **Step 3: implémenter le re câblage**

Dans `roles/system/core/files/usr/bin/transcript` :

a) En-tête (commentaire ligne ~6) :

```bash
# Dictation pipeline: arecord -> sox silence removal -> ffmpeg FLAC ->
# Gemini 3.5 Transcribe (smart rewriting by default, verbatim with --raw) ->
# wl-copy + ctrl+shift+v paste.
```

a2) Variables mortes : supprimer `inference_model=`, le bloc commentaire + `asr_language=`, et `llm_model=` (la dictée ne passe plus par DeepInfra ; `file_model`/`api_base` restent pour le mode fichier).

b) Runtime vars : supprimer la ligne `last_raw_file="${XDG_RUNTIME_DIR:-/tmp}/transcript-last-raw.txt"`.

c) Valeur par défaut : `clean_level="full"` → `clean_level="smart"`.

d) `usage()` : remplacer le heredoc par :

```bash
usage() {
    cat <<'EOF'
transcript - dictation and file transcription

Usage:
  transcript [--raw]                    toggle push-to-talk dictation
  transcript FILE [--srt]               write FILE.txt (and FILE.srt)

Options:
  --raw           verbatim transcription (no smart rewriting)
  --srt           with FILE: also write subtitles
  -h, --help      show this help

The last dictation's final text is kept in
$XDG_RUNTIME_DIR/transcript-last.txt for reference.
EOF
}
```

e) `stop_recording` — remplacer le bloc transcription+cleanup :

```bash
        text=""
        if ! text=$(transcribe_dictation "$processed_audio"); then
            job_state error
            exit 1
        fi
        if ! has_speech "$text"; then
            job_clear
            exit 0
        fi

        printf '%s' "$text" > "${last_out_file}.$BASHPID.tmp" && mv -f "${last_out_file}.$BASHPID.tmp" "$last_out_file"
```

(à la place des blocs `transcribe_audio … format_txt`, `has_speech`, `last_raw_file` write, `cleaning`/`llm_clean` et write `last_out_file` ; tout le reste du sous-shell — paste, garde anti-Super-coincé, `job_clear` — est inchangé).

f) `transcribe_audio` — simplifier (plus d'appelant dictée, plus de `asr_language`) :

```bash
# Transcribes audio via the DeepInfra inference API (file mode only:
# whisper keeps the segment timestamps --srt needs).
transcribe_audio() {
    local file="$1"
    api_call "ASR inference" \
        -X POST -H "Authorization: Bearer ${auth_token}" \
        -F "audio=@$file" \
        "${api_base}/v1/inference/${file_model}"
}
```

g) `process_file` : `transcribe_audio "$audio_file" "$file_model"` → `transcribe_audio "$audio_file"`.

h) Supprimer entièrement la fonction `llm_clean` (avec ses prompts).

i) Commentaire de `has_speech` : remplacer « Whisper returns 200 with empty… » par « Empty or punctuation-only output (e.g. noise surviving silence removal) is not an error. » (le corps reste identique).

j) `parse_args` — remplacer les branches `--clean` :

```bash
            --clean | --clean=*)
                echo "Error: --clean is gone — Gemini smart rewriting is built in; use --raw for verbatim" >&2
                exit 1
                ;;
```

et la validation : `if [[ ! "$clean_level" =~ ^(smart|raw)$ ]]; then` avec message `--clean must not be used; levels are smart (default) or raw (--raw)`.

k) `main` — clés par mode (le token DeepInfra n'est requis que pour le mode fichier) :

```bash
main() {
    parse_args "$@"
    check_dependencies

    if [[ -n "$input_file" ]]; then
        if ! auth_token=$(load_token) || [[ -z "$auth_token" ]]; then
            echo "Error: no API token found (set DEEPINFRA_API_TOKEN or create $token_file)" >&2
            exit 1
        fi
        process_file "$input_file"
        return
    fi

    if ! gemini_key=$(load_gemini_key) || [[ -z "$gemini_key" ]]; then
        echo "Error: no Gemini API key found (set GEMINI_API_KEY or create $gemini_key_file)" >&2
        mark_error
        exit 1
    fi

    if [[ -f "$recording_info" ]]; then
        local record_pid _
        read -r record_pid _ < "$recording_info"
        if ps -p "$record_pid" >/dev/null; then
            stop_recording
        else
            start_recording
        fi
    else
        start_recording
    fi
}
```

- [ ] **Step 4: vérifier le passage**

Run: `bash tests/transcript/run_tests.sh`
Expected: `All tests passed.`
Run: `bash -n roles/system/core/files/usr/bin/transcript`
Expected: pas d'erreur de syntaxe.

- [ ] **Step 5: commit**

```bash
git add roles/system/core/files/usr/bin/transcript tests/transcript/run_tests.sh
git commit -m "feat(transcript): dictation via Gemini smart transcription, drop LLM cleanup"
```

---

### Task 4b: préserver les audios « rejetés » (récupérabilité des échecs silencieux)

Ajout 2026-11-10 soir, demande utilisateur après une dictée perdue (job 21:42
ayant pris le chemin « pas de parole » : wav supprimé par le trap, /tmp en
tmpfs → contenu irrécupérable). Les deux chemins silencieux — trim vide
(`prepare_audio` échoue) et transcription vide (`has_speech` faux) —
préservent désormais l'enregistrement original pour retranscription manuelle.

**Files:**
- Modify: `roles/system/core/files/usr/bin/transcript` — nouvelle fonction `preserve_rejected` (près de `preserve`/helpers, après `cleanup_temps` ~ligne 108), deux call-sites dans `stop_recording`, sweep étendu dans `start_recording` (~ligne 153)
- Test: `tests/transcript/run_tests.sh` (insertion après les tests `job markers`, ~ligne 129)

**Interfaces:**
- Consumes: rien de nouveau.
- Produces: `preserve_rejected AUDIO` — déplace un fichier NON VIDE vers `/tmp/transcript-rejected-<horodatage>-<pid>.wav` (no-op silencieuse sur fichier absent/vide) ; sweep `start_recording` purgent les rejets >60 min.

- [ ] **Step 1: écrire les tests en échec**

Après le bloc `job markers` (après `rm -rf "$jobs_dir"`), ajouter :

```bash

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
if [[ ! -e "$probe" ]] && [[ -z "$leftover" ]]; then
    echo "ok - preserve_rejected skips empty files (left for trap cleanup)"
    rm -f "$probe"
else
    echo "FAIL - preserve_rejected must skip empty files"
    failures=$((failures + 1))
    rm -f "$probe" /tmp/transcript-rejected-*.wav
fi
```

Puis, dans le test `stop_recording` existant, juste après
`read -r rpid wavpath < "$recording_info"` et avant `stop_recording`, ajouter
(le wav non vide déclenche la préservation au lieu de la suppression) :

```bash
printf 'silent-but-nonempty-wav' > "$wavpath"
```

et remplacer l'assert de nettoyage :

```bash
assert_eq "$( [[ -e "$wavpath" ]] && echo leaked || echo cleaned )" "cleaned" "detached job removes the wav via trap"
```

par :

```bash
rejected="$(find /tmp -maxdepth 1 -name 'transcript-rejected-*.wav' -print -quit 2>/dev/null)"
if [[ ! -e "$wavpath" ]] && [[ -n "$rejected" ]]; then
    echo "ok - no-speech path preserves the recording for manual recovery"
    rm -f "$rejected"
else
    echo "FAIL - no-speech path must preserve the recording"
    failures=$((failures + 1))
    rm -f "$wavpath" /tmp/transcript-rejected-*.wav
fi
```

- [ ] **Step 2: vérifier l'échec**

Run: `bash tests/transcript/run_tests.sh`
Expected: FAIL `preserve_rejected: command not found` (assert vide) puis FAIL du test stop_recording intégré (wav non préservé).

- [ ] **Step 3: implémenter**

Après `cleanup_temps`, ajouter :

```bash
# Keeps a dictation whose processing found no speech: silent failures stay
# recoverable (the job's trap would otherwise delete the wav). Non-empty
# audio only — empty files hold nothing to recover. start_recording sweeps
# /tmp/transcript-rejected-*.wav older than 60 minutes, like orphaned
# recordings.
preserve_rejected() {
    local audio="$1"
    [[ -s "$audio" ]] || return 0
    mv "$audio" "/tmp/transcript-rejected-$(date +%Y%m%d-%H%M%S)-$$.wav" 2>/dev/null || true
}
```

Dans `start_recording`, étendre le sweep :

```bash
    find /tmp -maxdepth 1 \( -name 'recording_*.wav' -o -name 'transcript-rejected-*.wav' \) -mmin +60 -delete 2>/dev/null
```

Dans `stop_recording`, les deux chemins silencieux préservent (le `mv` sort
le fichier de `temp_files`, le trap ne le trouve plus) :

```bash
        processed_audio=""
        if ! processed_audio=$(prepare_audio "$tempfile"); then
            preserve_rejected "$tempfile"
            job_clear
            exit 0
        fi
```

```bash
        if ! has_speech "$text"; then
            preserve_rejected "$tempfile"
            job_clear
            exit 0
        fi
```

- [ ] **Step 4: vérifier le passage**

Run: `bash tests/transcript/run_tests.sh`
Expected: `All tests passed.`
Run: `bash -n roles/system/core/files/usr/bin/transcript`
Expected: rien.

- [ ] **Step 5: commit**

```bash
git add roles/system/core/files/usr/bin/transcript tests/transcript/run_tests.sh
git commit -m "feat(transcript): preserve no-speech recordings for manual recovery"
```

---

### Task 5: waybar — retrait de l'état « cleaning »

**Files:**
- Modify: `roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh:15-37`
- Modify: `roles/desktop/waybar/files/home/.config/waybar/style.css:241-244`

**Interfaces:**
- Consumes: les marqueurs de jobs du script `transcript` (après la Task 4, plus aucun job n'écrit `cleaning`).
- Produces: pill à 4 états (idle/recording/transcribing/error) — cohérente avec le script déployé.

- [ ] **Step 1: retirer les branches cleaning**

Dans `waybar-transcript.sh`, remplacer la boucle d'agrégation et le case d'affichage par :

```bash
if [[ "$state" != "recording" ]]; then
    # Priority: transcribing > error (work in progress wins; a finished
    # job's error stays visible until the next recording).
    for f in "$jobs_dir"/job-*; do
        [[ -e "$f" ]] || continue
        phase=$(<"$f")
        pid="${f##*/job-}"
        kill -0 "$pid" 2>/dev/null || [[ "$phase" == "error" ]] || continue
        case "$phase" in
            transcribing) state="transcribing" ;;
            error) [[ "$state" == "idle" ]] && state="error" ;;
        esac
        [[ "$state" == "transcribing" ]] && break
    done
fi

case "$state" in
    recording) text="🎤"; class="recording" ;;
    transcribing) text="⏳"; class="transcribing" ;;
    error) text="❌"; class="error" ;;
    *) text="🎙️"; class="idle" ;;
esac
```

Dans `style.css`, supprimer le bloc :

```css
#custom-transcript.cleaning {
    color: #bd93f9;
    animation: pulse 1s infinite;
}
```

- [ ] **Step 2: vérifier**

Run: `bash -n roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh`
Expected: pas d'erreur. Vérifier visuellement qu'aucune référence à `cleaning` ne subsiste : `grep -rn cleaning roles/desktop/waybar/` → rien.

- [ ] **Step 3: commit**

```bash
git add roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh roles/desktop/waybar/files/home/.config/waybar/style.css
git commit -m "feat(waybar): drop transcript cleaning state (single Gemini call)"
```

---

### Task 6: déploiement hôte + vérification end-to-end

**Files:**
- Deploy: `/usr/bin/transcript` (sudo cp), `~/.config/waybar/scripts/waybar-transcript.sh` (cp)
- Create hôte: `~/.config/transcript/gemini_key` (600, la clé validée en séance — **ne jamais la committer**), `~/.config/transcript/vocabulary` (amorçage jargon)

**Interfaces:**
- Consumes: tous les artefacts des tâches 1–5.
- Produces: dictée opérationnelle sur l'hôte ; validation réelle par l'utilisateur.

- [ ] **Step 1: déployer les scripts**

```bash
sudo cp roles/system/core/files/usr/bin/transcript /usr/bin/transcript
cp roles/desktop/waybar/files/home/.config/waybar/scripts/waybar-transcript.sh ~/.config/waybar/scripts/waybar-transcript.sh
```

(waybar relance le script à chaque `interval: 1` — pas de restart nécessaire.)

- [ ] **Step 2: installer la clé et le vocabulaire sur l'hôte**

```bash
install -d -m 700 ~/.config/transcript
# La clé Gemini validée pendant la séance (fournie par l'orchestrateur au
# moment de l'exécution ; NE PAS l'écrire dans un fichier du dépôt) :
#   printf '%s\n' '<CLÉ>' > ~/.config/transcript/gemini_key && chmod 600 ~/.config/transcript/gemini_key
printf '%s\n' hyprland Hyprland waybar Waybar vicinae DotArch ansible kitty zathura swaync > ~/.config/transcript/vocabulary
```

- [ ] **Step 3: vérification end-to-end sans micro**

Réutiliser l'échantillon de smoke test (`/tmp/gemtest2.flac`, ~13 s, fillers + loanwords ; le régénérer via espeak-ng si absent) et exercer **l'artefact installé** :

```bash
bash -c '
source /usr/bin/transcript
gemini_key=$(load_gemini_key)
clean_level="smart"
time transcribe_dictation /tmp/gemtest2.flac
'
```

Expected: HTTP implicite OK (pas d'erreur), sortie ≈ « Bonjour, alors je voudrais configurer Hyprland et Waybar sur Archlinux. The deadline is Friday. Voilà, c'est à peu près tout, merci. », latence ~3 s. Refaire un passage avec `clean_level="raw"` → verbatim avec fillers conservés.

- [ ] **Step 4: validation humaine**

L'utilisateur : toggle dictée (Super+A), parle, re-toggle → texte smart collé, pill waybar 🎤→⏳→🎙️ sans passer par « ✨ clean ». Un essai `transcript --raw`. Vérifier `~/.local/state/…` inutile ; au besoin consulter `$XDG_RUNTIME_DIR/transcript-last.txt`.

- [ ] **Step 5: commit final éventuel (rien à committer normalement)**

Tout le code a été committé en tâches 1–5 ; cette tâche ne touche que l'hôte. Si des correctifs surgissent de la Step 4, les committer en `fix(transcript): …` ciblés.
