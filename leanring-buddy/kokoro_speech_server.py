"""Long-lived Kokoro speech helper, driven over stdin/stdout.

Why a persistent process rather than one run per sentence: loading the model
costs around fifteen seconds cold. Paying that per sentence would make the
voice unusable, so the process stays up and the weights stay resident. Warm,
generation runs at roughly twice realtime, comfortably ahead of playback.

Protocol, one JSON object per line in each direction.

  in   {"text": "...", "voice": "af_heart", "speed": 0.95}
  out  {"ok": true, "path": "/tmp/....wav", "duration": 2.4}
       {"ok": false, "error": "..."}

On startup it emits {"ready": true} once the model is loaded, so the caller
knows when it is safe to send work.
"""
import json
import os
import sys
import tempfile
import time

OUTPUT_DIR = os.path.join(tempfile.gettempdir(), "clicky-kokoro")


def request_voice_default():
    """Voice used for the warm-up render.

    Compilation is per voice, so warming the one that will actually be used
    is what makes the first real sentence fast.
    """
    return os.environ.get("CLICKY_KOKORO_VOICE", "af_heart")


def emit(payload):
    """Writes one response line and flushes, since the caller blocks on it."""
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    try:
        import soundfile
        from kokoro_mlx import KokoroTTS
    except Exception as error:  # noqa: BLE001
        emit({"ready": False, "error": f"import failed: {error}"})
        return 1

    try:
        started = time.time()
        tts = KokoroTTS.from_pretrained("mlx-community/Kokoro-82M-bf16")
        load_seconds = time.time() - started
    except Exception as error:  # noqa: BLE001
        emit({"ready": False, "error": f"model load failed: {error}"})
        return 1

    # Render one throwaway phrase before reporting ready.
    #
    # Loading the weights is not the whole cost: MLX compiles its kernels on
    # the first generation, which measured 9.7 seconds against 1.4 for every
    # later sentence. Paid here that is startup time nobody is waiting on.
    # Paid on the first question it is nine seconds of silence after the user
    # has already finished speaking, which reads as the app being broken.
    warmup_seconds = 0.0
    try:
        warmup_started = time.time()
        tts.generate("ready", voice=request_voice_default(), speed=1.0)
        warmup_seconds = time.time() - warmup_started
    except Exception:  # noqa: BLE001
        # A failed warm-up is not fatal; the first real sentence simply pays
        # the compilation instead.
        pass

    emit({
        "ready": True,
        "load_seconds": round(load_seconds, 2),
        "warmup_seconds": round(warmup_seconds, 2),
    })

    # Each clip gets its own file; the caller deletes it after playing. Reusing
    # one path would race playback of the previous sentence against the write
    # of the next, which is routine here because generation outruns speech.
    clip_counter = 0

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as error:
            emit({"ok": False, "error": f"bad request: {error}"})
            continue

        text = (request.get("text") or "").strip()
        if not text:
            emit({"ok": False, "error": "empty text"})
            continue

        try:
            result = tts.generate(
                text,
                voice=request.get("voice", "af_heart"),
                speed=float(request.get("speed", 0.95)),
            )
            clip_counter += 1
            path = os.path.join(OUTPUT_DIR, f"clip_{os.getpid()}_{clip_counter}.wav")
            soundfile.write(path, result.audio, result.sample_rate)
            emit({"ok": True, "path": path, "duration": round(float(result.duration), 3)})
        except Exception as error:  # noqa: BLE001
            emit({"ok": False, "error": f"{type(error).__name__}: {error}"})

    return 0


if __name__ == "__main__":
    sys.exit(main())
