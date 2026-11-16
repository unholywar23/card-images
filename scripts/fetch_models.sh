#!/usr/bin/env bash
# fetch_models.sh - pull a named model set onto a rented card, fast.
# Weights are NOT baked into the images (keeps them small); this script grabs
# them at pod start over the datacentre's fat pipe (a few minutes).
#
# Speed: hf_transfer (parallel chunked HTTP) is forced on; each set downloads
# only the files that set needs.
#
# Usage:
#   fetch_models.sh <set> [<set> ...]        download one or more sets
#   fetch_models.sh all                      download every set (big)
#   fetch_models.sh --list                   show the sets and exit
#
# Sets, their official source, and licence are in SETS below. Dest defaults to
# /workspace/models/<set>; override with MODELS_DIR=/some/path.
set -euo pipefail

export HF_HUB_ENABLE_HF_TRANSFER=1
MODELS_DIR="${MODELS_DIR:-/workspace/models}"

# hf CLI (new) or huggingface-cli (old) - whichever is on the image.
if command -v hf >/dev/null 2>&1; then HF="hf download"; else HF="huggingface-cli download"; fi

# dl <repo> <dest-subdir> [include-pattern ...]
# No patterns = whole repo. Patterns = only those files.
dl() {
  local repo="$1"; local sub="$2"; shift 2
  local dest="${MODELS_DIR}/${sub}"
  mkdir -p "$dest"
  local inc=()
  for p in "$@"; do inc+=(--include "$p"); done
  echo ">> ${repo}  ->  ${dest}  ${*:+(}${*}${*:+)}"
  # --local-dir keeps real files (not a symlinked cache) so jobs can read them
  # directly; hf_transfer does the parallel download.
  ${HF} "$repo" "${inc[@]}" --local-dir "$dest"
}

SETS="animagine controlnet-sdxl z-image-turbo qwen-image-edit-2511 qwen3-tts ace-step-1.5 gemma-4 birefnet"

list_sets() {
  cat <<'EOF'
Model sets (name - what it is - official source - licence):

  animagine              Animagine XL 4.0 Opt checkpoint (anime SDXL)
                         cagliostrolab/animagine-xl-4.0  -  Fair AI Public License 1.0-SD

  controlnet-sdxl        ControlNet Union SDXL 1.0 ProMax (all control types)
                         xinsir/controlnet-union-sdxl-1.0  -  Apache-2.0

  z-image-turbo          Z-Image Turbo (ComfyUI repack) + its VAE + text encoder,
                         plus Z-Image Fun ControlNet Union 2.1 (8-step)
                         Comfy-Org/z_image_turbo  -  Apache-2.0
                         alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union-2.1  -  Apache-2.0

  qwen-image-edit-2511   Qwen-Image-Edit 2511 (instruction image edit)
                         Qwen/Qwen-Image-Edit-2511  -  Apache-2.0

  qwen3-tts              Qwen3-TTS 12Hz 1.7B (VoiceDesign + Base)
                         Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign  -  Apache-2.0
                         Qwen/Qwen3-TTS-12Hz-1.7B-Base  -  Apache-2.0

  ace-step-1.5           ACE-Step 1.5 music model + 5Hz planner LM
                         ACE-Step/Ace-Step1.5  -  MIT
                         ACE-Step/acestep-5Hz-lm-0.6B  -  MIT

  gemma-4                Gemma 4 E2B + E4B instruct (bf16) + stock Q4 GGUFs
                         unsloth/gemma-4-E2B-it , unsloth/gemma-4-E4B-it  -  Gemma Terms of Use
                         unsloth/gemma-4-E2B-it-GGUF , unsloth/gemma-4-E4B-it-GGUF

  birefnet               BiRefNet high-res background removal / matting
                         ZhengPeng7/BiRefNet  -  MIT
EOF
}

fetch_one() {
  case "$1" in
    animagine)
      dl cagliostrolab/animagine-xl-4.0 animagine "animagine-xl-4.0-opt.safetensors"
      ;;
    controlnet-sdxl)
      dl xinsir/controlnet-union-sdxl-1.0 controlnet-sdxl "diffusion_pytorch_model_promax.safetensors" "config.json"
      ;;
    z-image-turbo)
      dl Comfy-Org/z_image_turbo z-image-turbo \
         "z_image_turbo_bf16.safetensors" "ae.safetensors" "qwen_3_4b.safetensors"
      dl alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union-2.1 z-image-turbo \
         "Z-Image-Turbo-Fun-Controlnet-Union-2.1-2602-8steps.safetensors"
      ;;
    qwen-image-edit-2511)
      dl Qwen/Qwen-Image-Edit-2511 qwen-image-edit-2511
      ;;
    qwen3-tts)
      dl Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign qwen3-tts/VoiceDesign
      dl Qwen/Qwen3-TTS-12Hz-1.7B-Base qwen3-tts/Base
      ;;
    ace-step-1.5)
      # full repos (the working music job snapshotted the whole model; ACE-Step
      # needs the DiT + VAE + embedder + configs together)
      dl ACE-Step/Ace-Step1.5 ace-step-1.5/base
      dl ACE-Step/acestep-5Hz-lm-0.6B ace-step-1.5/planner
      ;;
    gemma-4)
      dl unsloth/gemma-4-E2B-it gemma-4/E2B-it
      dl unsloth/gemma-4-E4B-it gemma-4/E4B-it
      dl unsloth/gemma-4-E2B-it-GGUF gemma-4/gguf "gemma-4-E2B-it-Q4_K_M.gguf"
      dl unsloth/gemma-4-E4B-it-GGUF gemma-4/gguf "gemma-4-E4B-it-Q4_K_M.gguf"
      ;;
    birefnet)
      # full repo: BiRefNet loads with trust_remote_code, so it needs the .py
      # modeling files alongside the weights and config.
      dl ZhengPeng7/BiRefNet birefnet
      ;;
    *)
      echo "unknown set: $1" >&2
      echo "known: ${SETS}" >&2
      return 2
      ;;
  esac
}

if [ "$#" -eq 0 ] || [ "$1" = "--list" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  list_sets
  [ "$#" -eq 0 ] && { echo; echo "give one or more set names, or 'all'."; }
  exit 0
fi

if [ "$1" = "all" ]; then
  set -- ${SETS}
fi

t_start=$(date +%s)
for s in "$@"; do
  echo "=== fetching set: ${s} ==="
  s_start=$(date +%s)
  fetch_one "$s"
  echo "=== ${s} done in $(( $(date +%s) - s_start ))s ==="
done
echo "all requested sets done in $(( $(date +%s) - t_start ))s -> ${MODELS_DIR}"
