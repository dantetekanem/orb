#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Requires uv and an existing Python 3.12. Nothing is installed globally.
if [ ! -x .runtime/venv/bin/python ]; then
    uv venv --python 3.12 --no-python-downloads .runtime/venv
fi
UV_CACHE_DIR="$PWD/.runtime/uv-cache" uv pip install --python .runtime/venv/bin/python \
    --index-url https://pypi.org/simple -r voice-requirements.txt
mkdir -p .runtime/voices
base='https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0'
for model in 'en/en_GB/jenny_dioco/medium/en_GB-jenny_dioco-medium' \
             'en/en_GB/alan/medium/en_GB-alan-medium' 'en/en_US/lessac/high/en_US-lessac-high'; do
    for suffix in '.onnx' '.onnx.json'; do
        curl --fail --location --proto '=https' --silent --show-error \
            "$base/$model$suffix" -o ".runtime/voices/${model##*/}$suffix"
    done
done
shasum -a 256 -c voice-models.sha256
printf 'Jenny, Alan and Lessac are ready. Orb was not launched; no audio was played.\n'
