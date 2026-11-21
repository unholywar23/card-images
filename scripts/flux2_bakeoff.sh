#!/usr/bin/env bash
# flux2_bakeoff.sh -- set up FLUX.2 Klein 4B for the Kota pose bake-off ON a rented
# card, WITHOUT disturbing the art image's pinned diffusers 0.37.1.
#
# WHY this is a separate venv and NOT baked into the art image
# ------------------------------------------------------------
# The art image ships diffusers==0.37.1 on purpose: that exact version carries the
# Qwen-Image-Edit and Z-Image pipelines AND sits inside ACE-Step 1.5's requirement
# range (diffusers>=0.37, transformers>=4.51,<4.58). FLUX.2 Klein 4B needs a MUCH
# newer diffusers -- its model card installs diffusers from git main and uses
# `Flux2KleinPipeline`, a class that does NOT exist in 0.37.1. Upgrading diffusers
# in the shared image to get FLUX.2 would break the ACE-Step / Z-Image / Qwen-Edit
# pins that every running art job depends on.
#
# So FLUX.2 Klein is treated like the olmOCR/Surya OCR challengers: a bake-off
# candidate installed AT TEST TIME in its own throwaway venv, not a baked tool. If
# it wins the Qwen-vs-Klein pose bake-off (Kota audit, head-to-head B), THEN we
# decide whether it earns a place -- most likely still in its own venv, because of
# the diffusers clash.
#
# Usage (on the card, after SSH-in):
#   bash flux2_bakeoff.sh setup      # make /opt/flux2 venv with git diffusers
#   bash flux2_bakeoff.sh fetch      # pull FLUX.2-klein-4B weights
#   /opt/flux2/bin/python your_pose_script.py   # run the 5 poses
set -euo pipefail

VENV="${FLUX2_VENV:-/opt/flux2}"
MODELS_DIR="${MODELS_DIR:-/workspace/models}"
export HF_HUB_ENABLE_HF_TRANSFER=1

case "${1:-}" in
setup)
  # uv is on the art image; it builds the isolated venv fast. Fall back to stdlib venv.
  if command -v uv >/dev/null 2>&1; then
    uv venv "$VENV" --python 3.11
    # git diffusers = the only source that currently carries Flux2KleinPipeline.
    uv pip install --python "$VENV/bin/python" \
      "git+https://github.com/huggingface/diffusers.git" \
      transformers accelerate safetensors sentencepiece protobuf pillow \
      "torch==2.10.0" --torch-backend=auto
  else
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --upgrade pip
    "$VENV/bin/pip" install "git+https://github.com/huggingface/diffusers.git" \
      transformers accelerate safetensors sentencepiece protobuf pillow \
      torch==2.10.0 --extra-index-url https://download.pytorch.org/whl/cu128
  fi
  "$VENV/bin/python" - <<'PY'
import diffusers
from diffusers import Flux2KleinPipeline   # must import, or the bake-off cannot run
print("flux2 venv OK: diffusers", diffusers.__version__, "has Flux2KleinPipeline")
PY
  echo ">> FLUX.2 venv ready at $VENV (the art image's diffusers 0.37.1 is untouched)"
  ;;
fetch)
  dest="$MODELS_DIR/flux2-klein-4b"
  mkdir -p "$dest"
  if command -v hf >/dev/null 2>&1; then HF="hf download"; else HF="huggingface-cli download"; fi
  # 4B (Apache, free-to-sell). The 9B is NON-commercial -- do NOT fetch it.
  ${HF} black-forest-labs/FLUX.2-klein-4B --local-dir "$dest"
  echo ">> FLUX.2 Klein 4B weights at $dest"
  ;;
*)
  sed -n '2,33p' "$0"; exit 1 ;;
esac
