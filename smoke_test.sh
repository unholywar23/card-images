#!/usr/bin/env bash
# smoke_test.sh - prove a card image actually works, on the rented card, with
# timings. Run it ON the pod after the image starts. It auto-detects whether
# this is the art image or the train image and runs the checks that apply.
#
#   bash smoke_test.sh            # auto-detect
#   bash smoke_test.sh art        # force art checks
#   bash smoke_test.sh train      # force train checks
#
# Each check prints PASS/FAIL and how long it took. Exit code is non-zero if any
# check failed. No weights needed: the tiny ones each check needs are fetched.
set -uo pipefail

WHICH="${1:-auto}"
PASS=0; FAIL=0
TOOLS_DIR="${TOOLS_DIR:-/workspace/tools}"
TMP=/tmp/smoke; mkdir -p "$TMP"

say()  { echo; echo "=== $* ==="; }
ok()   { echo "PASS  $1  (${2}s)"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1  (${2}s)"; FAIL=$((FAIL+1)); }

have_art=0; have_train=0
[ -d /opt/ComfyUI ] && have_art=1
[ -d /opt/llama.cpp ] && have_train=1
case "$WHICH" in
  art)   have_art=1; have_train=0 ;;
  train) have_train=1; have_art=0 ;;
esac

# ---- shared: torch sees the card ----------------------------------------------
say "torch sees the card"
t=$(date +%s)
if python - <<'PY'
import torch, sys
assert torch.cuda.is_available(), "cuda not available"
print("torch", torch.__version__, "->", torch.cuda.get_device_name(0))
PY
then ok "torch+cuda" $(( $(date +%s) - t )); else bad "torch+cuda" $(( $(date +%s) - t )); fi

# ---- art checks ---------------------------------------------------------------
if [ "$have_art" = 1 ]; then

  say "ComfyUI starts"
  t=$(date +%s)
  ( cd /opt/ComfyUI && python main.py --listen 127.0.0.1 --port 8188 --disable-auto-launch >"$TMP/comfy.log" 2>&1 & echo $! >"$TMP/comfy.pid" )
  ready=0
  for _ in $(seq 1 60); do
    if curl -sf http://127.0.0.1:8188/system_stats >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
  done
  kill "$(cat "$TMP/comfy.pid")" 2>/dev/null || true
  if [ "$ready" = 1 ]; then ok "comfyui-start" $(( $(date +%s) - t )); else bad "comfyui-start" $(( $(date +%s) - t )); tail -5 "$TMP/comfy.log"; fi

  say "Blender renders one frame on the card (OptiX)"
  t=$(date +%s)
  cat > "$TMP/blender_smoke.py" <<PY
import bpy, sys
sys.path.insert(0, "${TOOLS_DIR}")
from blender_card_only import card_only
bpy.ops.mesh.primitive_cube_add()
bpy.ops.object.light_add(type='SUN')
cam = bpy.data.objects.new("c", bpy.data.cameras.new("c")); bpy.context.scene.collection.objects.link(cam)
cam.location = (5,-5,4); bpy.context.scene.camera = cam
s = bpy.context.scene
card_only(s, samples=16)
s.render.resolution_x = 256; s.render.resolution_y = 256
s.render.filepath = "${TMP}/frame_"
bpy.ops.render.render(write_still=True)
PY
  if blender -b -P "$TMP/blender_smoke.py" >"$TMP/blender.log" 2>&1 && grep -q "CARD ONLY: OPTIX" "$TMP/blender.log" && ls "${TMP}"/frame_*.png >/dev/null 2>&1; then
    ok "blender-optix" $(( $(date +%s) - t ))
  else
    bad "blender-optix" $(( $(date +%s) - t )); grep -iE "card only|optix|error" "$TMP/blender.log" | tail -5
  fi

  say "headless Chromium draws on the card (ANGLE/Vulkan, not SwiftShader)"
  t=$(date +%s)
  export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p "$XDG_RUNTIME_DIR"
  if python - <<'PY'
from playwright.sync_api import sync_playwright
import sys
args=['--headless=new','--no-sandbox','--use-gl=angle','--use-angle=vulkan',
      '--ozone-platform=headless','--enable-gpu','--ignore-gpu-blocklist','--disable-dev-shm-usage']
with sync_playwright() as p:
    b=p.chromium.launch(headless=True,args=args); pg=b.new_page()
    r=pg.evaluate("""()=>{const c=document.createElement('canvas');const gl=c.getContext('webgl2')||c.getContext('webgl');if(!gl)return'no-webgl';const e=gl.getExtension('WEBGL_debug_renderer_info');return e?gl.getParameter(e.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER);}""")
    b.close(); print("renderer:",r)
    sys.exit(0 if ('NVIDIA' in str(r) and 'SwiftShader' not in str(r)) else 3)
PY
  then ok "chromium-gpu" $(( $(date +%s) - t )); else bad "chromium-gpu (drew on SwiftShader/CPU)" $(( $(date +%s) - t )); fi

  say "ACE-Step makes 10 seconds of audio"
  t=$(date +%s)
  if [ ! -d /workspace/models/ace-step-1.5 ]; then
    echo "(fetching ace-step-1.5 weights first)"; fetch_models.sh ace-step-1.5 >"$TMP/ace_fetch.log" 2>&1 || true
  fi
  cat > "$TMP/ace.toml" <<TOML
caption = "a short calm piano phrase"
lyrics = "[Instrumental]"
instrumental = true
duration = 10.0
seed = 42
inference_steps = 30
shift = 3.0
save_dir = "${TMP}/ace"
audio_format = "flac"
batch_size = 1
use_random_seed = false
checkpoint_dir = "/workspace/models/ace-step-1.5/base"
offload_to_cpu = false
task_type = "text2music"
vocal_language = "unknown"
TOML
  mkdir -p "$TMP/ace"
  if ( cd /opt/ACE-Step && python cli.py -c "$TMP/ace.toml" ) >"$TMP/ace.log" 2>&1 && ls "$TMP"/ace/*.flac >/dev/null 2>&1; then
    ok "ace-step-10s" $(( $(date +%s) - t ))
  else
    bad "ace-step-10s" $(( $(date +%s) - t )); tail -8 "$TMP/ace.log"
  fi
fi

# ---- train checks -------------------------------------------------------------
if [ "$have_train" = 1 ]; then

  say "Unsloth imports"
  t=$(date +%s)
  if python -c "import unsloth; print('unsloth', getattr(unsloth,'__version__','?'))"; then
    ok "unsloth-import" $(( $(date +%s) - t ))
  else bad "unsloth-import" $(( $(date +%s) - t )); fi

  say "llama.cpp runs on the card"
  t=$(date +%s)
  GGUF="$TMP/tiny.gguf"
  if [ ! -f "$GGUF" ]; then
    echo "(fetching a tiny GGUF to drive the card)"
    HF_HUB_ENABLE_HF_TRANSFER=1 hf download Qwen/Qwen2.5-0.5B-Instruct-GGUF \
      --include "qwen2.5-0.5b-instruct-q4_k_m.gguf" --local-dir "$TMP/ggufdir" >"$TMP/gguf.log" 2>&1 \
      && cp "$TMP"/ggufdir/*.gguf "$GGUF"
  fi
  if /opt/llama.cpp/build/bin/llama-cli -m "$GGUF" -ngl 99 -n 16 -p "hello" --no-warmup >"$TMP/llama.log" 2>&1 \
     && grep -qiE "CUDA[0-9]|ggml_cuda_init: found|using CUDA" "$TMP/llama.log"; then
    ok "llamacpp-card" $(( $(date +%s) - t ))
  else
    bad "llamacpp-card" $(( $(date +%s) - t )); grep -iE "cuda|error|device" "$TMP/llama.log" | tail -6
  fi

  say "llama-quantize + llama-imatrix present"
  t=$(date +%s)
  if /opt/llama.cpp/build/bin/llama-quantize --help >/dev/null 2>&1 && /opt/llama.cpp/build/bin/llama-imatrix --help >/dev/null 2>&1; then
    ok "llamacpp-tools" $(( $(date +%s) - t ))
  else bad "llamacpp-tools" $(( $(date +%s) - t )); fi
fi

say "result"
echo "PASS=${PASS}  FAIL=${FAIL}"
[ "$FAIL" = 0 ] && echo "SMOKE_OK" || echo "SMOKE_FAILED"
exit "$FAIL"
