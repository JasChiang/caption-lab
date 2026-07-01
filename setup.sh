#!/usr/bin/env bash
# Bootstraps the Qwen (MLX) forced-aligner backend for CaptionLab.
# Creates a local .venv and installs mlx-audio (MLX only — no torch pulled on purpose).
# Idempotent: safe to re-run. The Swift app finds .venv/bin/python + aligner/qwen_align.py
# relative to the repo root (override with $CAPTIONLAB_PYTHON / $CAPTIONLAB_ALIGNER).
set -euo pipefail

cd "$(dirname "$0")"
VENV=".venv"
PYVER="3.12"

echo "==> CaptionLab Qwen backend setup"

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

[ -x "$VENV/bin/python" ] || create_venv

echo "==> Installing mlx-audio (MLX only; no torch)"
if command -v uv >/dev/null 2>&1; then
  uv pip install --python "$VENV/bin/python" mlx-audio
else
  "$VENV/bin/python" -m pip install --upgrade pip
  "$VENV/bin/python" -m pip install mlx-audio
fi

echo "==> Verifying import"
"$VENV/bin/python" - <<'PY'
import mlx_audio  # noqa: F401
print("mlx-audio import OK")
PY

cat <<EOF

==> Done. Qwen backend ready.
    - Python:  $(pwd)/$VENV/bin/python
    - Sidecar: $(pwd)/aligner/qwen_align.py
    - The Qwen model 'mlx-community/Qwen3-ForcedAligner-0.6B-8bit' (~hundreds of MB, 8-bit)
      auto-downloads on the FIRST alignment run — needs network that once, then it is cached.
    - Peak RAM per alignment ~2.2 GB (fine on 16 GB); the app serializes aligner runs.

    Next: set GEMINI_API_KEY (or use the in-GUI key field), then:
      DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run CaptionLab
EOF
