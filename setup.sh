#!/usr/bin/env bash
# Bootstraps the optional Python sidecar backends for CaptionLab into a local .venv.
#   ./setup.sh          Qwen (MLX) forced-aligner A/B lane  → installs mlx-audio (default; back-compat)
#   ./setup.sh --asr    Local offline ASR "second ear"      → installs mlx-whisper
#   ./setup.sh --all    both
# All MLX only — no torch pulled on purpose. Idempotent: safe to re-run. The Swift app finds
# .venv/bin/python + the sidecars (aligner/qwen_align.py, asr/local_asr.py) relative to the repo root
# (override with $CAPTIONLAB_PYTHON / $CAPTIONLAB_ALIGNER / $CAPTIONLAB_ASR_SCRIPT).
set -euo pipefail

cd "$(dirname "$0")"
VENV=".venv"
PYVER="3.12"

WANT_QWEN=0
WANT_ASR=0
case "${1:-}" in
  --asr) WANT_ASR=1 ;;
  --all) WANT_QWEN=1; WANT_ASR=1 ;;
  ""|--qwen) WANT_QWEN=1 ;;
  *) echo "Usage: ./setup.sh [--asr | --all | --qwen]" >&2; exit 1 ;;
esac

echo "==> CaptionLab sidecar setup (qwen=$WANT_QWEN asr=$WANT_ASR)"

create_venv() {
  if command -v uv >/dev/null 2>&1; then
    echo "==> Creating venv with uv (python $PYVER)"
    uv venv --python "$PYVER" "$VENV"
  elif command -v "python$PYVER" >/dev/null 2>&1; then
    echo "==> Creating venv with python$PYVER"
    "python$PYVER" -m venv "$VENV"
  elif command -v python3 >/dev/null 2>&1; then
    echo "==> uv and python$PYVER not found; falling back to python3"
    python3 -m venv "$VENV"
  else
    echo "ERROR: no uv / python$PYVER / python3 found. Install Python $PYVER (e.g. 'brew install python@3.12' or 'uv')." >&2
    exit 1
  fi
}

pipinstall() {
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$VENV/bin/python" "$@"
  else
    "$VENV/bin/python" -m pip install "$@"
  fi
}

[ -x "$VENV/bin/python" ] || create_venv
command -v uv >/dev/null 2>&1 || "$VENV/bin/python" -m pip install --upgrade pip

if [ "$WANT_QWEN" = 1 ]; then
  echo "==> Installing mlx-audio (Qwen forced-aligner; MLX only, no torch)"
  pipinstall mlx-audio
  "$VENV/bin/python" - <<'PY'
import mlx_audio  # noqa: F401
print("mlx-audio import OK")
PY
fi

if [ "$WANT_ASR" = 1 ]; then
  echo "==> Installing mlx-whisper (local offline ASR; MLX only, no torch)"
  pipinstall mlx-whisper
  "$VENV/bin/python" - <<'PY'
import mlx_whisper  # noqa: F401
print("mlx-whisper import OK")
PY
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "    NOTE: mlx-whisper decodes audio via ffmpeg — install it once: brew install ffmpeg"
  fi
fi

cat <<EOF

==> Done.
    - Python:  $(pwd)/$VENV/bin/python
$( [ "$WANT_QWEN" = 1 ] && echo "    - Qwen aligner sidecar: $(pwd)/aligner/qwen_align.py
      Model 'mlx-community/Qwen3-ForcedAligner-0.6B-8bit' auto-downloads on first run (~hundreds of MB)." )
$( [ "$WANT_ASR" = 1 ] && echo "    - Local ASR sidecar:    $(pwd)/asr/local_asr.py
      Default model 'mlx-community/whisper-large-v3-mlx' auto-downloads on first run.
      Override with \$CAPTIONLAB_ASR_MODEL (e.g. a locale-tuned checkpoint for Taiwan Mandarin).
      Used by stage 5 when you pick 'Local ASR (offline)' / pass --refine-local." )

    Next: set GEMINI_API_KEY (or use the in-GUI key field), then:
      DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run CaptionLab
EOF
