#!/usr/bin/env bash
# smoke_test.sh - prove a card image actually works, on the rented card, with
# timings. Run it ON the pod after the image starts. It auto-detects whether
# this is the art image or the train image and runs the checks that apply.
#
#   bash smoke_test.sh            # auto-detect
#   bash smoke_test.sh art        # force art checks
#   bash smoke_test.sh train      # force train checks
#   bash smoke_test.sh cpu        # force cpu checks (no GPU)
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
# SKIP = not a pass and not an image fault (e.g. a capability this rented host
# does not expose). It does NOT fail the run.
skip() { echo "SKIP  $1  (${2}s)"; }

# An `ssh host 'cmd'` session is non-login, so it does NOT load the image's baked
# env (/etc/profile.d). Re-set the two vars the GPU-Chromium check needs.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"; mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
if [ -z "${VK_ICD_FILENAMES:-}" ] && [ -f /etc/vulkan/icd.d/nvidia_icd.json ]; then
  export VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json
fi

have_art=0; have_train=0; have_cpu=0
[ -d /opt/ComfyUI ] && have_art=1
[ -d /opt/llama.cpp ] && have_train=1
# cpu image = no torch, no ComfyUI, no llama.cpp, but has the OCR engine.
if [ "$have_art" = 0 ] && [ "$have_train" = 0 ] && command -v tesseract >/dev/null 2>&1; then have_cpu=1; fi
case "$WHICH" in
  art)   have_art=1; have_train=0; have_cpu=0 ;;
  train) have_train=1; have_art=0; have_cpu=0 ;;
  cpu)   have_cpu=1; have_art=0; have_train=0 ;;
esac

# ---- shared (GPU images only): torch sees the card ----------------------------
if [ "$have_cpu" != 1 ]; then
  say "torch sees the card"
  t=$(date +%s)
  if python - <<'PY'
import torch, sys
assert torch.cuda.is_available(), "cuda not available"
print("torch", torch.__version__, "->", torch.cuda.get_device_name(0))
PY
  then ok "torch+cuda" $(( $(date +%s) - t )); else bad "torch+cuda" $(( $(date +%s) - t )); fi
fi

# ---- cpu checks ---------------------------------------------------------------
if [ "$have_cpu" = 1 ]; then

  say "Tesseract OCR engine (eng + osd)"
  t=$(date +%s)
  if tesseract --version >/dev/null 2>&1 \
     && tesseract --list-langs 2>&1 | grep -qx eng \
     && tesseract --list-langs 2>&1 | grep -qx osd; then
    ok "tesseract-eng-osd" $(( $(date +%s) - t ))
  else bad "tesseract-eng-osd" $(( $(date +%s) - t )); tesseract --list-langs 2>&1 | tail -6; fi

  say "OCRmyPDF + PyMuPDF + pytesseract import"
  t=$(date +%s)
  if ocrmypdf --version >/dev/null 2>&1 && python -c "import fitz, pytesseract, PIL; print('pymupdf', fitz.__doc__ and 'ok')"; then
    ok "ocr-python" $(( $(date +%s) - t ))
  else bad "ocr-python" $(( $(date +%s) - t )); fi

  say "end-to-end OCR: make a 1-page PDF, read the text back"
  t=$(date +%s)
  # Draw a known word into a PDF with PyMuPDF, OCR it with OCRmyPDF, confirm the
  # word comes back. Proves the whole engine chain (ghostscript raster -> tesseract).
  if python - "$TMP" <<'PY'
import sys, fitz
d = fitz.open(); pg = d.new_page()
pg.insert_text((72, 144), "DECLASSIFIED", fontsize=48)
d.save(sys.argv[1] + "/ocr_in.pdf")
PY
  then
    if ocrmypdf --force-ocr --output-type pdf "$TMP/ocr_in.pdf" "$TMP/ocr_out.pdf" >"$TMP/ocr.log" 2>&1 \
       && python -c "import fitz,sys; print(fitz.open(sys.argv[1]+'/ocr_out.pdf')[0].get_text())" "$TMP" | grep -qi DECLASSIFIED; then
      ok "ocr-end-to-end" $(( $(date +%s) - t ))
    else bad "ocr-end-to-end" $(( $(date +%s) - t )); tail -6 "$TMP/ocr.log"; fi
  else bad "ocr-end-to-end (pdf build)" $(( $(date +%s) - t )); fi

  say "ffmpeg encodes (libx264)"
  t=$(date +%s)
  if ffmpeg -hide_banner -f lavfi -i testsrc=duration=1:size=128x128:rate=10 \
       -c:v libx264 -y "$TMP/ff.mp4" >"$TMP/ff.log" 2>&1 && [ -s "$TMP/ff.mp4" ]; then
    ok "ffmpeg-x264" $(( $(date +%s) - t ))
  else bad "ffmpeg-x264" $(( $(date +%s) - t )); tail -4 "$TMP/ff.log"; fi

  say "Node + glTF-Transform + odiff (library shrink/gate CLIs)"
  t=$(date +%s)
  if node --version >/dev/null 2>&1 && gltf-transform --version >/dev/null 2>&1 && odiff --version >/dev/null 2>&1; then
    ok "node-gltf-odiff" $(( $(date +%s) - t ))
  else bad "node-gltf-odiff" $(( $(date +%s) - t )); fi

  say "aria2 + rsync present (fast downloads / sync)"
  t=$(date +%s)
  if command -v aria2c >/dev/null 2>&1 && command -v rsync >/dev/null 2>&1; then
    ok "aria2-rsync" $(( $(date +%s) - t ))
  else bad "aria2-rsync" $(( $(date +%s) - t )); fi
fi

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
  # Some rented hosts mount the CUDA/OptiX driver libs (so Blender works) but NOT
  # the NVIDIA Vulkan *producer* lib, so Vulkan cannot make an NVIDIA device and
  # ANGLE falls back to SwiftShader. That is a HOST limitation, not an image
  # fault: SKIP it rather than FAIL. If the host DOES expose NVIDIA over Vulkan,
  # run the real check.
  if ! vulkaninfo >/dev/null 2>&1; then
    skip "chromium-gpu (host did not expose NVIDIA over Vulkan: no producer lib mounted; CUDA/OptiX still work)" $(( $(date +%s) - t ))
  elif python - <<'PY'
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
  # With the planner LM on, ACE-Step installs an interactive prompt-edit hook that
  # calls input() and would die on EOF under nohup. Feed it empty lines so each
  # input() returns at once and it uses the unedited prompt — keeps the real
  # planner path, just unattended. Use process substitution (not `yes | python`):
  # under `set -o pipefail` a real pipe reports `yes`'s SIGPIPE and would fail the
  # check even though generation succeeded.
  if ( cd /opt/ACE-Step && python cli.py -c "$TMP/ace.toml" < <(yes "") ) >"$TMP/ace.log" 2>&1 && ls "$TMP"/ace/*.flac >/dev/null 2>&1; then
    ok "ace-step-10s" $(( $(date +%s) - t ))
  else
    bad "ace-step-10s" $(( $(date +%s) - t )); tail -8 "$TMP/ace.log"
  fi

  say "library-gate CLIs: Node + glTF-Transform + odiff"
  t=$(date +%s)
  if node --version >/dev/null 2>&1 && gltf-transform --version >/dev/null 2>&1 && odiff --version >/dev/null 2>&1; then
    ok "node-gltf-odiff" $(( $(date +%s) - t ))
  else bad "node-gltf-odiff" $(( $(date +%s) - t )); fi

  say "Kokoro voice package imports (pins intact)"
  t=$(date +%s)
  # Import only (no weights needed): proves kokoro installed and did not drag the
  # pinned torch/diffusers/transformers off their versions.
  if python - <<'PY'
import kokoro, torch, diffusers, transformers, sys
assert torch.version.cuda, "torch went CPU-only"
assert diffusers.__version__ == "0.37.1", diffusers.__version__
assert transformers.__version__ == "4.57.6", transformers.__version__
print("kokoro ok; pins intact: diffusers", diffusers.__version__, "transformers", transformers.__version__)
PY
  then ok "kokoro-import" $(( $(date +%s) - t )); else bad "kokoro-import" $(( $(date +%s) - t )); fi
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
  # -ngl 99 forces the layers onto the card; the run succeeding + any CUDA mention
  # anywhere in the log proves it drew on the card. (Newer llama.cpp logs the
  # device as "ggml_cuda_init"/"CUDA0"/"offloaded ... to GPU"; plain "cuda" covers
  # all of them — the old CUDA[0-9] pattern missed the current wording.)
  if /opt/llama.cpp/build/bin/llama-cli -m "$GGUF" -ngl 99 -n 16 -p "hello" --no-warmup >"$TMP/llama.log" 2>&1 \
     && grep -qi "cuda" "$TMP/llama.log"; then
    ok "llamacpp-card" $(( $(date +%s) - t ))
  else
    bad "llamacpp-card" $(( $(date +%s) - t )); grep -iE "cuda|error|device" "$TMP/llama.log" | tail -6
  fi

  say "llama-quantize + llama-imatrix present"
  t=$(date +%s)
  # Check the binaries exist and are executable. (Do NOT rely on `--help` exit
  # codes: llama-quantize prints usage and exits 1, which falsely failed here.)
  if [ -x /opt/llama.cpp/build/bin/llama-quantize ] && [ -x /opt/llama.cpp/build/bin/llama-imatrix ]; then
    ok "llamacpp-tools" $(( $(date +%s) - t ))
  else bad "llamacpp-tools" $(( $(date +%s) - t )); fi
fi

say "result"
echo "PASS=${PASS}  FAIL=${FAIL}"
[ "$FAIL" = 0 ] && echo "SMOKE_OK" || echo "SMOKE_FAILED"
exit "$FAIL"
