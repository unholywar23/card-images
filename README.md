# card-images

Ready-made Docker images so a rented NVIDIA card (RunPod) starts working in about
a minute instead of 15-20. Everything a job needs is baked in; only the model
weights download at pod start (a few minutes on the datacentre's pipe).

Three images. Two GPU images (the training stack and the art stack conflict, so
they stay separate) and one slim CPU image for processor-only jobs:

| Image | What it's for | Key contents |
|---|---|---|
| `card-images-art` | drawing, image edit, music, TTS, Blender renders, headless Chromium, the library glTF gate, Kota voice | torch 2.10 (cu128), ComfyUI (pinned), diffusers/transformers, ACE-Step 1.5, Blender 4.2 LTS, Playwright Chromium, ffmpeg, **Node LTS + odiff + glTF-Transform**, **Kokoro-82M voice** |
| `card-images-train` | fine-tuning + GGUF quantizing | torch 2.8 (cu126), Unsloth + TRL/PEFT, llama.cpp built with CUDA (quantize, imatrix, server, cli) |
| `card-images-cpu` | **CPU pods**: bulk OCR, media encode, glTF room compression, downloads | Tesseract (eng+osd) + OCRmyPDF + PyMuPDF, ffmpeg, Node LTS + glTF-Transform + odiff, aria2/rsync/git-lfs — **no CUDA, no torch** |

Images are published to GitHub's registry:

```
ghcr.io/<owner>/card-images-art:latest     (and a :YYYYMMDD date tag)
ghcr.io/<owner>/card-images-train:latest
ghcr.io/<owner>/card-images-cpu:latest
```

They are public because this repository is public. No login is needed to pull.

## Why these versions

- **CUDA:** torch wheels carry their own CUDA runtime, so they run on RunPod
  hosts with **driver 550** (CUDA 12.4, by CUDA 12.x minor-version compatibility
  — a 12.x build runs on any ≥12.0 driver in the 12 family) **and driver 595**
  (CUDA 13.2).
  - **art image → torch 2.10 (cu128).** This is ACE-Step 1.5's exact Linux pin at
    the commit we use (torch 2.10.0+cu128, torchvision 0.25.0, torchaudio 2.10.0,
    torchao 0.16), so ACE-Step runs on its tested stack. torch 2.10 is also a
    superset for the drawing stack — ComfyUI at the pinned commit ran on torch
    2.14 on 2026-11-15, and diffusers 0.37 / transformers 4.57 support 2.10 — so
    one torch serves ComfyUI, the diffusers pipelines, and ACE-Step. (Plain torch
    2.8+cu126 ran the drawing jobs on driver 550 that day but does **not** satisfy
    ACE-Step's torchao 0.16 pin, which is why the art image standardises on 2.10.)
  - **train image → torch 2.8 (cu126),** the drawing-day baseline, which Unsloth
    supports and which has no competing pin in the training stack.
- **Cards:** RTX 4090 and L40S are `sm_89`, A40 is `sm_86`. The torch wheels ship
  kernels for all three, and `llama.cpp` is compiled for `sm_86;sm_89`, so the
  same image runs on any of them with no per-card build.
- No model weights are inside the images (keeps them buildable on GitHub's
  runner). `fetch_models.sh` pulls them at pod start.

## How a job uses them

1. **Deploy a RunPod pod** with the image as the template / image override:
   - art job → `ghcr.io/<owner>/card-images-art:latest`
   - training job → `ghcr.io/<owner>/card-images-train:latest`
   - Expose TCP port 22 and set the pod's `PUBLIC_KEY`. The image's entrypoint
     installs that key and starts `sshd` on port 22 the same way RunPod's own
     templates do.
   - **RunPod does NOT pass the account's SSH key to a custom template** (found
     2026-11-16: both test cards refused the key until `PUBLIC_KEY` was set by
     hand, and setting it on a running pod resets it and changes its SSH port).
     Fix in place since 2026-11-16 04:35: both private templates
     (`card-images-art` id `1pndku56tn`, `card-images-train` id `7jeizvwgx0`)
     now carry the env var `PUBLIC_KEY` = the public half of `buddy_proof`.
     Rent from `https://console.runpod.io/deploy?template=<id>`; a card is
     ready for SSH about 6 minutes after it is made (image pull + unpack).
2. **SSH in** (the pod shows the host/port).
3. **First command — fetch the weights the job needs:**
   ```bash
   fetch_models.sh animagine controlnet-sdxl      # art example
   fetch_models.sh gemma-4                         # training example
   fetch_models.sh --list                          # see every set
   ```
   Models land in `/workspace/models/<set>`.
4. **Work.** ComfyUI is at `/opt/ComfyUI`, ACE-Step at `/opt/ACE-Step`,
   llama.cpp at `/opt/llama.cpp/build/bin` (and `llama-quantize` / `llama-imatrix`
   / `llama-server` / `llama-cli` are on `PATH`). The `tools/cards` helpers are
   at `/workspace/tools`:
   - `blender_card_only.py` — import it in every Blender job so the render uses
     the **card only** (OptiX), never the processor.
   - `card_busy.sh` — run it ~1 minute after any render/train starts to confirm
     the card is actually doing the work.
   - `pod_watchdog.py` — the card's **own** idle kill switch. Start it once at
     job start so a forgotten card can never bill for long even if the PC is off
     (the PC-side watchdog can't reach it then). It terminates the pod itself on
     idle, on a work-done marker, or at a hard life cap:
     ```bash
     nohup python3 /workspace/tools/pod_watchdog.py --idle-minutes 20 \
           --done-marker /workspace/.card_done >/workspace/pod_watchdog.log 2>&1 &
     # ...then, as the job's LAST step after results are home:
     touch /workspace/.card_done
     ```
     Full notes + options: `tools/cards/pod_watchdog/README.md`.

### Model sets

`fetch_models.sh --list` prints each set, its official source, and its licence.
Current sets: `animagine`, `controlnet-sdxl`, `z-image-turbo`,
`qwen-image-edit-2511`, `qwen3-tts`, `ace-step-1.5`, `gemma-4`, `birefnet`,
`kokoro` (the Kota voice), `zimage-lora-train`.

## Blender on the card

Every Blender job must force the card:

```python
import sys; sys.path.insert(0, "/workspace/tools")
from blender_card_only import card_only
card_only(bpy.context.scene)      # OptiX, card only; raises if no NVIDIA card
```

## Headless Chromium on the card

The image sets `VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json` and
`XDG_RUNTIME_DIR=/tmp/xdg`. Launch Chromium with ANGLE/Vulkan so it draws on the
card, not SwiftShader:

```
--headless=new --no-sandbox --use-gl=angle --use-angle=vulkan
--ozone-platform=headless --enable-gpu --ignore-gpu-blocklist --disable-dev-shm-usage
```

Confirm the renderer string contains `NVIDIA` and not `SwiftShader`.

## CPU pods (`card-images-cpu`)

Jobs that only need processors — bulk OCR (Tesseract/OCRmyPDF), media encode
(ffmpeg), glTF-Transform room compression (Node), plain downloads — used to rent
the 8.5 GB **art** GPU image just to get "an Ubuntu box with plenty of CPUs" (the
archive OCR job brief says exactly that). That meant a 10-20 min pull for work
that never touches a card. `card-images-cpu` is a few hundred MB and starts in
about a minute.

Deploy a **RunPod CPU pod** with this image (or the `card-images-cpu` template,
below). It has no GPU and no CUDA. From a script:

```
venv\Scripts\python.exe rent.py <request> --cpu            # best default (cpu3c-4-8)
venv\Scripts\python.exe rent.py <request> --cpu --instance cpu3c-8-16   # more cores
```

What's baked in: `python3` + pip, **Tesseract (eng + osd)**, **OCRmyPDF** +
PyMuPDF + pytesseract + Pillow + numpy, **ffmpeg**, **Node LTS + @gltf-transform/cli
+ odiff**, git/git-lfs, aria2, rsync, plus the `tools/cards` helpers and the same
`sshd`/`PUBLIC_KEY` entrypoint as the GPU images. No model weights — `fetch_models.sh`
still works for the rare CPU job that needs one.

Smoke test it the same way: `bash smoke_test.sh cpu`.

**One-time setup for the CPU template (Andrew, needs the RunPod key):** `rent.py
--cpu` deploys a `card-images-cpu` RunPod template that carries the image +
`PUBLIC_KEY` (same shape as the GPU templates). RunPod > Templates > New Template,
image `ghcr.io/<owner>/card-images-cpu:latest`, Container Disk ~20 GB, expose TCP
port 22, add env `PUBLIC_KEY` = the public half of `buddy_proof`. Save its id (one
line) into `cards/cpu_template_id.txt`. Until that file exists, `rent.py --cpu`
prints these exact steps and stops — it never guesses a template.

## New in v2 (2026-11-20): library gate, Kota voice, FLUX.2

The art image gained the tools Fable's best-tools switches need, baked as **late
layers** so they do not invalidate the multi-GB torch/ComfyUI/ACE-Step/Blender
cached layers on a rebuild:

- **Library glTF gate** — `node` (LTS), `odiff` (the blocking pixel-diff gate),
  and `gltf-transform` (weld + meshopt room compression) are on `PATH`. Before
  this, `run_gate.sh` fell back to a slower numpy diff when a host had no node, and
  pods reported "this host had no node" and installed pieces by hand. The Megascans
  re-skin itself is Blender work (already baked).
- **Kota voice** — the `kokoro` package (Kokoro-82M, Apache, male voices) + its
  `espeak-ng` g2p are baked; the 82 M weights come from `fetch_models.sh kokoro`.
  A build-time assert proves installing kokoro did **not** drag the pinned
  torch/diffusers 0.37.1/transformers 4.57.6 off their versions.

**FLUX.2 Klein 4B does NOT run on this image's diffusers, and that is on purpose.**
The art image pins `diffusers==0.37.1` because that exact version carries the
Qwen-Image-Edit and Z-Image pipelines **and** sits inside ACE-Step 1.5's
requirement range (diffusers ≥0.37, transformers ≥4.51,<4.58). FLUX.2 Klein 4B
needs a much newer diffusers — its model card installs diffusers from **git main**
and uses `Flux2KleinPipeline`, a class that does not exist in 0.37.1. Upgrading
diffusers in the shared image to get FLUX.2 would break the ACE-Step / Z-Image /
Qwen-Edit pins every running art job depends on. So FLUX.2 Klein is treated like
the olmOCR/Surya OCR challengers: a **bake-off candidate installed at test time in
its own throwaway venv**, never baked. The exact Qwen-vs-Klein bake-off setup is
`scripts/flux2_bakeoff.sh` (makes `/opt/flux2` with git diffusers, fetches the 4B
Apache weights — the 9B is non-commercial, skip it). If Klein wins the Kota pose
bake-off, it still lives in its own venv because of the diffusers clash.

## Image sizes & pull speed

Measured from the published ghcr manifests (compressed, what a fresh host pulls):

| Image | Compressed size | Fresh pull (RunPod, ~2026-11) | Biggest layers |
|---|---|---|---|
| `card-images-art` (build #4) | **8.5 GB**, 23 layers | ~10-20 min on a new host | torch+cu128 trio ~4.0 GB; CUDA/cuDNN base ~1.4 GB; ComfyUI+ACE-Step deps ~0.8+0.9 GB; Playwright Chromium ~0.4 GB |
| `card-images-train` (build #4) | **12.3 GB**, 24 layers | ~12-20 min | CUDA **devel** toolchain + llama.cpp build ~3.3+2.4 GB; torch cu126 ~3.2 GB; CUDA/cuDNN base ~1.4 GB (shared with art) |
| `card-images-cpu` (v2, new) | **~0.4-0.5 GB** (no CUDA/torch) | **~1 min** | apt base + Tesseract/ffmpeg/Node ~0.3 GB; python OCR deps ~0.1 GB |

**The big fresh-pull win is the CPU image** (≈8.5 GB → ≈0.4 GB for OCR/encode/
compress jobs — a ~20× smaller pull, ~1 min vs 10-20 min). The art and train
images are dominated by torch + CUDA, which the GPU work genuinely needs, so there
is no safe multi-GB trim to the proven stacks without a real-card smoke test
(cards are on hold). Two bigger GPU-image trims are **staged, not shipped**, each
needing a real-card smoke test before it can replace `:latest`:

1. **Art slim base** — the image is `FROM nvidia/cuda:12.6.3-cudnn-runtime` *and*
   installs torch cu128, which bundles its own CUDA 12.8 runtime + cuDNN. The base
   image's CUDA/cuDNN (~1.4 GB layer) is largely redundant for the torch workloads
   (Blender OptiX and Chromium Vulkan use the **mounted driver**, not the base
   libs). Dropping to the `-base` CUDA image could save ~1.4-2 GB (~20% of the art
   pull). Risk: an unproven break to OptiX/Vulkan — must be smoke-tested on a card.
2. **Train multi-stage** — llama.cpp is built in-place on the `-devel` base, so the
   ~3 GB CUDA **toolchain** (nvcc etc.) ships in the final image though nothing at
   runtime needs it. A multi-stage build (build llama.cpp in a devel stage, copy
   only the binaries into a runtime base) could cut the train image by several GB.
   Risk: a missing runtime CUDA lib — must be smoke-tested on a card.

On a host that already pulled one GPU image, the CUDA/cuDNN base layer (~1.4 GB,
digest `ed090066…`) and the small apt/tools layers are **shared**, so the second
GPU image pulls that much less.

## Building / updating

GitHub Actions (`.github/workflows/build.yml`) builds **all three** images on every
push to `main` that touches a Dockerfile, `scripts/`, or `tools/`, and pushes
them to ghcr.io with a date tag and `:latest`. It frees runner disk first so the
big CUDA images fit. You can also run it by hand from the Actions tab
(**workflow_dispatch**).

To change a version, edit the `ARG` lines at the top of the Dockerfile and push:

- `Dockerfile.art`: `TORCH_VERSION`, `TORCH_INDEX`, `COMFYUI_COMMIT`,
  `ACESTEP_COMMIT`, `BLENDER_VERSION`, `NODE_MAJOR`, `GLTF_TRANSFORM_SPEC`,
  `ODIFF_SPEC`.
- `Dockerfile.train`: `TORCH_VERSION`, `TORCH_INDEX`, `LLAMA_CUDA_ARCHS`.
- `Dockerfile.cpu`: `NODE_MAJOR`, `OCRMYPDF_SPEC`, `GLTF_TRANSFORM_SPEC`,
  `ODIFF_SPEC`.

### Version notes / known knobs

- **ACE-Step** is installed from its own `requirements.txt` at the pinned commit,
  so it gets its tested dependency set (torchao 0.16, lightning, gradio, etc.) on
  top of torch 2.10+cu128 — the trio its requirements pin. `nano-vllm` is a local
  package in the repo and is installed from its path. The only thing dropped is
  the Linux `flash-attn` line: it compiles from source (needs the CUDA toolkit a
  runtime base doesn't carry) and ACE-Step generation runs without it. If a job's
  planner needs flash-attn, install a matching **prebuilt** wheel at pod start.
- **Unsloth** is installed unpinned on top of the pinned torch (Buddy's training
  runs used the current Unsloth, which was never pinned). If a run needs a
  specific Unsloth, pin it on the `unsloth` line in `Dockerfile.train`.

## Testing

`smoke_test.sh` runs **on the pod** after the image starts and proves, with
timings, that: torch sees the card; (art) ComfyUI starts, Blender renders one
frame with OptiX, Chromium draws on the card, ACE-Step makes 10 seconds of
audio, the library-gate CLIs (node/odiff/gltf-transform) run, and kokoro imports
with the pins intact; (train) Unsloth imports, llama.cpp runs on the card,
quantize/imatrix are present; (cpu) Tesseract eng+osd, an end-to-end OCR of a
generated PDF, ffmpeg x264, node/gltf-transform/odiff, aria2/rsync. It
auto-detects which image it's on.

```bash
bash smoke_test.sh          # auto
bash smoke_test.sh art
bash smoke_test.sh train
bash smoke_test.sh cpu
```

## Verified on real cards (2026-11-16)

Both images from GitHub build #4 (commit `7f1a20a`) were pulled onto rented cards
(RTX 4090 for art, A40 for train; both on NVIDIA driver 595 / CUDA 13.2) and smoke
tested. Each pod was usable within ~6 minutes of being made (image pull + unpack),
versus the old 15–20 minutes of per-pod installs.

**ART image — READY.** torch 2.10+cu128 on the card, ComfyUI starts (10s), Blender
renders a frame with OptiX (2s), ACE-Step makes 10s of audio (DiT 0.82s), and
`fetch_models.sh` ran at full datacentre speed (ACE-Step 11 GB in 19s; BiRefNet
425 MB in 3s). One capability is **host-dependent, not an image fault:** headless
Chromium drew on SwiftShader on this host because RunPod did not mount the NVIDIA
*Vulkan producer* lib (`vkCreateInstance → ERROR_INCOMPATIBLE_DRIVER`); CUDA/OptiX
compute is mounted, so Blender works. `smoke_test.sh` now SKIPs this check (instead
of failing) when the host does not expose NVIDIA over Vulkan.

**TRAIN image — FIX MADE IN REPO, NEEDS A REBUILD BEFORE USE.** Build #4's train
image shipped two breakages for Gemma-4 work, both fixed in `Dockerfile.train` here
and **not yet pushed/rebuilt**:
1. `torch 2.11.0+cpu` (torchao, pulled by the unsloth stack, dragged torch off the
   cu126 GPU build) → no CUDA.
2. `transformers 4.57.6` (the convert-reqs step downgraded it) → Gemma-4's
   `model_type "gemma4"` is unrecognised, so the LoRA merge fails.

   The fix re-pins `transformers==5.17.0` and force-reinstalls the cu126 torch trio
   as the **last** step, with a build-time assert that torch has CUDA. Once rebuilt,
   a training job is: deploy the train image → `fetch_models.sh gemma-4` → merge /
   convert / quantize. Until then, a train pod must apply the same two re-pins by
   hand (see `PUSH_THESE.md`). The llama.cpp tools, Unsloth import, and GGUF
   quantize all work; Buddy's small-brain ship file was re-exported on this card
   after the two re-pins (see `../jobs/images_smoke/`).

See `PUSH_THESE.md` for the exact files to push.

## Studio (Room 7 / Half Past Weird) card setup

The art image covers every tool the studio needs for painting, voices, lip-sync and renders.
After SSH-in, one fetch command gets the painter, voices and their models:

```bash
# Painter (Z-Image Turbo bf16 + ControlNet Union 2.1) + voices (Qwen3-TTS VoiceDesign + Base)
fetch_models.sh z-image-turbo qwen3-tts
```

Blender (4.2 LTS, OptiX) and Rhubarb Lip Sync (1.14.0, CPU) are baked in — no fetch needed.
FFmpeg is baked in. ACE-Step music weights are a separate fetch:

```bash
fetch_models.sh ace-step-1.5     # music (optional for most studio jobs)
```

For per-character LoRA training (the trained add-on that keeps the same man in every shot),
use the **train image** and fetch the trainer + adapter together:

```bash
fetch_models.sh z-image-turbo zimage-lora-train
# then: pod_train_lora.py --model /workspace/models/z-image-turbo \
#         --adapter /workspace/models/zimage_turbo_training_adapter \
#         --ai-toolkit /workspace/ai-toolkit  [+ --character, --sheet-dir, --out-dir]
```

### What is in the art image for the studio

| Studio job | Tool | Baked / fetched |
|---|---|---|
| Painted plates | Z-Image Turbo bf16 (diffusers `ZImagePipeline`) | fetched: `z-image-turbo` |
| Plate ControlNet (stand-in guide) | Z-Image ControlNet Union 2.1 | same set |
| Character voices (design + clone) | Qwen3-TTS 1.7B VoiceDesign + Base (`qwen-tts` package) | fetched: `qwen3-tts` |
| Mouth cues (lip-sync) | Rhubarb Lip Sync 1.14.0 (`rhubarb` on PATH) | **baked** |
| Blender renders | Blender 4.2 LTS, OptiX via mounted driver | **baked** |
| Video / audio encode | FFmpeg | **baked** |
| Music | ACE-Step 1.5 turbo | fetched: `ace-step-1.5` |
| Character sheet matting | BiRefNet | fetched: `birefnet` |
| LoRA training (same man) | ostris/ai-toolkit + zimage_turbo_training_adapter | fetched: `zimage-lora-train` (**train image**) |

### diffusers version note

The art image ships `diffusers==0.37.1`. `ZImagePipeline` (the base painter) is present in
this build. The Z-Image ControlNet Union pipeline class name in diffusers is not settled as of
this build — `pod_zimage.py` tries the three likely names and reports the exact failure if none
is found, so the plain-painter numbers still come back even if the ControlNet wiring is not
yet in this diffusers release. If a ControlNet run is needed before diffusers exposes the class,
use ComfyUI's Z-Image Fun ControlNet node (already in the `z-image-turbo` fetch set, same weights).

### Rhubarb note

Rhubarb 1.14.0 is baked in at build time from the official GitHub release ZIP
(`DanielSWolf/rhubarb-lip-sync`, MIT). It is a Linux x86_64 static binary; no Python deps;
runs with `rhubarb --version` to confirm. The studio's `tools.lipsync()` calls it as
`rhubarb -f json -r pocketSphinx --extendedShapes GHX`.

### Publishing these changes

Publishing requires a push to the `main` branch of this repository, which triggers GitHub
Actions (`build.yml`) to rebuild and push both images to `ghcr.io/<owner>/card-images-art:latest`
and `ghcr.io/<owner>/card-images-train:latest`. That requires Andrew's GitHub account (the
repository owner). No login or push is done here — the files are ready, uncommitted.
