#!/usr/bin/env python3
"""CaptionLab local ASR sidecar — a general, OFFLINE "second ear" (mlx-whisper, MLX only).

Transcribes an audio file with a LOCAL Whisper-family model on Apple Silicon and prints the verbatim
result as a normalized JSON object to STDOUT — the stable contract the Swift side depends on:

    {"text": "<verbatim transcript>", "language": "<detected/given>",
     "segments": [{"text": "<...>", "start": <seconds float>, "end": <seconds float>}, ...]}

The MODEL IS A KNOB, not a hardcode: --model / $CAPTIONLAB_ASR_MODEL selects it and DEFAULTS to a general
multilingual Whisper, so nothing in the pipeline is bound to one language. Point it at a locale-tuned
checkpoint when you want that — e.g. for Taiwan Mandarin + code-switching:

    CAPTIONLAB_ASR_MODEL=mlx-community/whisper-large-v3-mlx   # general default (works out of the box)
    CAPTIONLAB_ASR_MODEL=<your-mlx-converted-Breeze-ASR-25>   # opt-in, locale-tuned (needs MLX weights)

Usage:
    python local_asr.py --audio path.wav [--language zh] [--model <id>] [--prompt "proper nouns…"]

Only STDOUT carries the JSON. Progress bars / logs from mlx-whisper go to STDERR. On failure this exits
non-zero and writes a one-line JSON error object to STDERR (STDOUT stays empty), so the caller never has
to parse mixed output.
"""
import argparse
import json
import os
import sys

DEFAULT_MODEL = os.environ.get("CAPTIONLAB_ASR_MODEL", "mlx-community/whisper-large-v3-mlx")


def fail(msg: str, code: int = 1):
    sys.stderr.write(json.dumps({"error": msg}) + "\n")
    sys.exit(code)


def main() -> int:
    ap = argparse.ArgumentParser(description="Local Whisper ASR sidecar (mlx-whisper).")
    ap.add_argument("--audio", required=True, help="Path to an audio file (16 kHz mono WAV recommended).")
    ap.add_argument("--language", default=None, help="ISO code (zh, en, ja, …); omit to auto-detect.")
    ap.add_argument("--model", default=DEFAULT_MODEL, help="MLX Whisper repo/dir. Default: a general multilingual model.")
    ap.add_argument("--prompt", default=None, help="Optional initial-prompt bias (e.g. proper nouns from the content map).")
    args = ap.parse_args()

    if not os.path.isfile(args.audio):
        fail(f"audio file not found: {args.audio}")

    try:
        import mlx_whisper  # noqa: WPS433
    except Exception as e:  # noqa: BLE001
        fail(f"mlx-whisper not importable — run ./setup.sh --asr (or pip install mlx-whisper): {e}")

    # Verbatim, no cleanup: the caller wants what was ACTUALLY said (repeats/false starts included) so the
    # map-agreement gate downstream can judge it. word_timestamps off — timing is assigned by the Swift side
    # on energy peaks, exactly like the Gemini retranscribe path.
    kwargs = {"path_or_hf_repo": args.model, "word_timestamps": False, "condition_on_previous_text": False}
    if args.language:
        kwargs["language"] = args.language
    if args.prompt:
        kwargs["initial_prompt"] = args.prompt[:220]

    try:
        result = mlx_whisper.transcribe(args.audio, **kwargs)
    except Exception as e:  # noqa: BLE001
        fail(f"transcription failed with model '{args.model}': {e}")

    text = str(result.get("text", "")).strip()
    segments = []
    for seg in (result.get("segments") or []):
        if not isinstance(seg, dict):
            continue
        t = str(seg.get("text", "")).strip()
        if not t:
            continue
        try:
            segments.append({"text": t, "start": float(seg.get("start")), "end": float(seg.get("end"))})
        except (TypeError, ValueError):
            continue

    json.dump({"text": text, "language": result.get("language"), "segments": segments},
              sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
