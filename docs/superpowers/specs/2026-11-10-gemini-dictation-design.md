# Migration de la dictée vers Gemini 3.5 Transcribe (batch smart)

Date : 2026-11-10
Statut : design validé par l'utilisateur, en attente de plan d'implémentation.

## Contexte

Le script `transcript` (rôle `system/core`, déployé dans `/usr/bin/transcript`)
chaîne aujourd'hui deux appels DeepInfra pour la dictée : ASR
(whisper-large-v3-turbo sur l'hôte, Voxtral-Small dans le dépôt) puis nettoyage
LLM (DeepSeek-V4.1-Flash). Deux griefs :

1. **Qualité** — l'ASR actuel fait des erreurs récurrentes (loanwords FR/EN,
   jargon technique).
2. **Latence** — la chaîne à deux appels allonge l'attente après le stop.

Google a sorti **Gemini 3.5 Transcribe** (août 2026), le moteur de la dictée
Gboard/Gmail/Chrome : un seul modèle qui transcrit **et** réécrit (mode
« smart » : suppression des fillers/hésitations, auto-corrections appliquées,
ponctuation, mise en forme). Exposé en API publique REST, format FLAC accepté,
envoi inline base64 (≤100 Mo par requête, pas d'API Files nécessaire).

## Décisions

- **Périmètre : dictée uniquement.** Le mode fichier (`transcript FICHIER
  --srt`) reste sur whisper/DeepInfra, inchangé.
- **Deux niveaux** : défaut = `smart` (réécriture intégrée, 1 appel) ;
  `--raw` = `verbatim` Gemini (transcription exacte, 1 appel). `--clean
  light|full` supprimés.
- **Compte : prépayé** (carte renseignée ; recharger 5 $ minimum sur
  ai.studio/projects — les requêtes échouent en 402 tant que le solde est nul,
  et pas de free tier tant que le billing est actif). Données non utilisées
  pour l'entraînement en payant.
- **Batch, pas live** pour l'instant : le mode live (`gemini-3.5-transcribe-live`,
  WebSocket, VAD serveur, finals smart à chaque pause) est différé — l'utilisateur
  fait des pauses longues pour réfléchir (le VAD finaliserait à chaque pause) et
  le silence-trim local économise des tokens audio facturés.
- **Vocabulaire custom** : si `~/.config/transcript/vocabulary` existe (un
  terme par ligne), il est envoyé en `custom_vocabulary` (≤1000 termes).

## API

Endpoint : `POST https://generativelanguage.googleapis.com/v1beta/interactions`,
header `x-goog-api-key: $KEY`.

Requête (dictée) :

```json
{
  "model": "models/gemini-3.5-transcribe",
  "input": [{"type": "audio", "data": "<base64 FLAC>", "mime_type": "audio/flac"}],
  "generation_config": {"transcription_config": {
    "mode": "smart",
    "custom_vocabulary": ["hyprland", "waybar"]
  }}
}
```

- `mode` : `"smart"` (défaut) ou `{"type": "verbatim"}` pour `--raw`.
  Le mode smart est incompatible avec diarization/timestamps — non utilisés ici.
- `language_codes` : omis → auto-détection avec code-switching (85+ langues).
- Réponse : texte dans `steps[].content[].text`, extraction jq confirmée :
  `[.steps[].content[]?.text // empty] | join("")`.
- **Vocabulaire custom envoyé dans les deux modes** (smart et verbatim) :
  smoke test 2026-11-10 — sans vocabulaire, « hyprland et waybar sur
  archlinux » (TTS) devient « le Wi-Fi sur un Linux » ; avec, restitution
  parfaite y compris la casse.
- Smoke test 2026-11-10 (compte prépayé, ~13 s d'audio) : smart et verbatim
  en ~2,9 s, fillers retirés et auto-correction fondue en smart, loanword
  EN conservé, usage 315 tokens audio + 35 sortie ≈ 0,001 $/dictée.
- Tarif : ~0,005 $/min en blend (2 $/M tokens audio entrée, 12 $/M sortie).

## Changements du script

Fichier : `roles/system/core/files/usr/bin/transcript` (déployé par
`roles/system/core/tasks/scripts.yml`, déjà en place).

- **Ajouts** :
  - `gemini_model`, `gemini_api_base` ; `load_gemini_key()` (env
    `GEMINI_API_KEY` puis `~/.config/transcript/gemini_key`, sur le modèle de
    `load_token` qui reste pour DeepInfra/mode fichier).
  - `transcribe_dictation()` : construit la requête (b64 du FLAC, mode
    smart/verbatim selon niveau, vocabulaire custom si présent), passe par
    `api_call` (retry 3× / backoff conservés), extrait le texte via jq.
- **Suppressions** :
  - `llm_clean()` et les prompts de nettoyage (plus de seconde passe) ;
    `inference_model` / `asr_language` (variables ASR dictée DeepInfra) ;
    écriture de `transcript-last-raw.txt`.
  - État de job `cleaning` (le waybar pill « ✨ clean » disparaît) :
    retirer la branche correspondante de `waybar-transcript.sh`.
- **Modifications** :
  - `parse_args` : défaut `clean_level="smart"` ; `--raw` conserve son
    raccourci ; `--clean …` → erreur explicite (« supprimé, remplacé par le
    mode smart Gemini intégré »). Usage mise à jour.
  - Message d'erreur dédié sur HTTP 402 (« crédits prépayés épuisés —
    recharger sur ai.studio/projects »).
- **Inchangés** : `arecord`, sox silence-removal (seuil 0.6 %), conversion
  FLAC, garde « < 0.25 s ⇒ pas d'appel », `has_speech`, jobs parallèles
  détachés, garde anti-Super-coincé avant le paste, `wl-copy` +
  ctrl+shift+v, mode fichier intégral.

## Secrets

La clé Gemini vit uniquement sur l'hôte (`~/.config/transcript/gemini_key`)
ou dans l'env — jamais dans le dépôt. Aucun changement vault / `encrypt.sh`.

## Tests

- **Unitaires** (`tests/transcript/run_tests.sh`, script sourcé + fakes) :
  - supprimer les tests `llm_clean` ;
  - ajuster `parse_args` (défaut smart, `--raw`, `--clean` rejeté) ;
  - nouveaux : construction de requête smart/verbatim (mode, vocabulaire
    injecté seulement si le fichier existe), extraction de texte depuis une
    fixture de réponse Interactions, `load_gemini_key` env→fichier, message 402.
- **Banc réel** : smoke test curl effectué 2026-11-10 (résultats dans la
  section API ci-dessus) ; reste à valider sur dictées réelles de
  l'utilisateur après déploiement.
- **Déploiement** : tests unitaires verts → `sudo cp` vers `/usr/bin/transcript`
  pour la phase de test (validation par dictées réelles) → déploiement ansible
  (`scripts.yml` copie déjà le fichier du dépôt) pour officialiser.

## Hors périmètre / futur

- **Mode live** : `gemini-3.5-transcribe-live` en WebSocket
  (`BidiGenerateContent`), PCM brut 16 kHz mono ~100 ms/chunk, VAD serveur,
  interims tapés en direct + finals smart par pause, `audio_stream_end` au
  toggle-off, dépendance `websocat`. Reprise possible plus tard sans rien
  jeter du présent travail.
- Migration du mode fichier vers Gemini (verbatim + timestamps mot-à-mot,
  SRT à reconstruire).
- Revert : commit unique annulable (git revert).
