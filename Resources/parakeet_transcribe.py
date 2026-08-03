#!/usr/bin/env python3
"""
parakeet_transcribe.py — Parakeet-MLX audio transcription sidecar.

Usage:
    python3 parakeet_transcribe.py <audio_file_path>

Prints exactly one JSON object to stdout on success:
    {"text": "transcribed text here"}

All progress, warnings, and errors go to stderr. On failure, exits non-zero
with an error message on stderr — stdout is never written on failure.

Requirements (developer install):
    pip install parakeet-mlx

API verified 2026-07-02 against:
    - https://github.com/senstella/parakeet-mlx (README)
    - https://pypi.org/project/parakeet-mlx/
  Both sources show:
    from parakeet_mlx import from_pretrained
    model = from_pretrained("mlx-community/parakeet-tdt-0.6b-v3")
    result = model.transcribe(path)
    text = result.text
  NOTE: the recommended/default model id is v3 (parakeet-tdt-0.6b-v3), not v2.

AUDIO FORMAT: our Swift AudioRecorder writes CoreAudio Format (.caf) files.
parakeet-mlx's documented CLI/API formats are "WAV, MP3, etc." via ffmpeg;
CAF support is not documented, so any .caf input is transcoded to a 16-bit
PCM WAV via macOS's built-in `afconvert` before being handed to the model.

The Swift ParakeetEngine spawns this script via Process() and reads stdout.
stderr is captured separately and forwarded to os_log on the Swift side.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"


def main() -> None:
    if len(sys.argv) < 2:
        _error_exit("Usage: parakeet_transcribe.py <audio_file_path>")

    audio_path = Path(sys.argv[1])
    if not audio_path.exists():
        _error_exit(f"Audio file not found: {audio_path}")

    try:
        from parakeet_mlx import from_pretrained  # type: ignore[import]
    except ImportError:
        _error_exit(
            "parakeet-mlx not installed. Run: pip install parakeet-mlx\n"
            "See README for details."
        )
        return

    wav_path: Path | None = None
    transcribe_path = audio_path

    try:
        if audio_path.suffix.lower() == ".caf":
            wav_path = _transcode_caf_to_wav(audio_path)
            transcribe_path = wav_path

        print(f"Loading model {MODEL_ID}…", file=sys.stderr, flush=True)
        model = from_pretrained(MODEL_ID)

        print(f"Transcribing {transcribe_path}…", file=sys.stderr, flush=True)
        result = model.transcribe(str(transcribe_path))
        text = result.text if hasattr(result, "text") else str(result)

        # stdout must be strictly JSON-only: exactly one object, nothing else.
        sys.stdout.write(json.dumps({"text": text}))
        sys.stdout.write("\n")
        sys.stdout.flush()
    except Exception as exc:  # noqa: BLE001
        _error_exit(f"Transcription failed: {exc}")
    finally:
        if wav_path is not None and wav_path.exists():
            try:
                wav_path.unlink()
            except OSError as cleanup_exc:
                print(
                    f"Warning: failed to remove tempfile {wav_path}: {cleanup_exc}",
                    file=sys.stderr,
                    flush=True,
                )


def _transcode_caf_to_wav(caf_path: Path) -> Path:
    """Transcode a .caf file to 16-bit PCM WAV via macOS's `afconvert`.

    parakeet-mlx's documented input formats are WAV/MP3/etc via ffmpeg; CAF
    is not documented as supported, so we transcode via the OS-provided tool
    rather than risk an unsupported-format failure inside the model.
    """
    fd, tmp_name = tempfile.mkstemp(suffix=".wav", prefix="parakeet_")
    import os

    os.close(fd)
    wav_path = Path(tmp_name)

    print(f"Transcoding {caf_path.name} → WAV via afconvert…", file=sys.stderr, flush=True)
    try:
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16", str(caf_path), str(wav_path)],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        wav_path.unlink(missing_ok=True)
        raise RuntimeError(
            f"afconvert failed (exit {exc.returncode}): {exc.stderr.strip()}"
        ) from exc
    except FileNotFoundError as exc:
        wav_path.unlink(missing_ok=True)
        raise RuntimeError("afconvert not found — this sidecar requires macOS.") from exc

    return wav_path


def _error_exit(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)
    sys.exit(1)


if __name__ == "__main__":
    main()
