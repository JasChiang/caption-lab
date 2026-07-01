#!/usr/bin/env bash
# Loads .env (GEMINI_API_KEY etc.) then launches CaptionLab so the GUI key field
# is pre-filled from the environment. The Swift app does NOT read .env itself —
# this wrapper does. Any args are passed straight through (e.g. a media path, or --cli).
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a            # export everything sourced below
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "note: GEMINI_API_KEY is empty — Gemini stages will be skipped/degraded." >&2
  echo "      Put your key in .env (GEMINI_API_KEY=…) or paste it into the GUI field." >&2
fi

exec swift run CaptionLab "$@"
