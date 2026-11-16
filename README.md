# card-images

Ready-made Docker images so a rented NVIDIA card (RunPod) starts working in about
a minute instead of 15-20. Everything a job needs is baked in; only the model
weights download at pod start (a few minutes on the datacentre's pipe).

Two images, because the training stack and the art stack conflict:

| Image | What it's for | Key contents |
|---|---|---|
| `card-images-art` | drawing, image edit, music, TTS, Blender renders, headless Chromium | torch 2.10 (cu128), ComfyUI (pinned), diffusers/transformers, ACE-Step 1.5, Blender 4.2 LTS, Playwright Chromium, ffmpeg |
| `card-images-train` | fine-tuning + GGUF quantizing | torch 2.8 (cu126), Unsloth + TRL/PEFT, llama.cpp built with CUDA (quantize, imatrix, server, cli) |

Images are published to GitHub's registry:

```
ghcr.io/<owner>/card-images-art:latest     (and a :YYYYMMDD date tag)
ghcr.io/<owner>/card-images-train:latest
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
   - **RunPod does NOT pass the account's SSH key to a custom template.** Set the
     env var `PUBLIC_KEY` (your public SSH key) on the template itself, or on each
     pod (setting it on a running pod resets the pod and changes its SSH port).
     With the key on the template, a card answers SSH about 6 minutes after it
     is made (image pull + unpack).
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

### Model sets

`fetch_models.sh --list` prints each set, its official source, and its licence.
Current sets: `animagine`, `controlnet-sdxl`, `z-image-turbo`,
`qwen-image-edit-2511`, `qwen3-tts`, `ace-step-1.5`, `gemma-4`, `birefnet`.

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

## Building / updating

GitHub Actions (`.github/workflows/build.yml`) builds **both** images on every
push to `main` that touches a Dockerfile, `scripts/`, or `tools/`, and pushes
them to ghcr.io with a date tag and `:latest`. It frees runner disk first so the
big CUDA images fit. You can also run it by hand from the Actions tab
(**workflow_dispatch**).

To change a version, edit the `ARG` lines at the top of the Dockerfile and push:

- `Dockerfile.art`: `TORCH_VERSION`, `TORCH_INDEX`, `COMFYUI_COMMIT`,
  `ACESTEP_COMMIT`, `BLENDER_VERSION`.
- `Dockerfile.train`: `TORCH_VERSION`, `TORCH_INDEX`, `LLAMA_CUDA_ARCHS`.

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
audio; (train) Unsloth imports, llama.cpp runs on the card, quantize/imatrix are
present. It auto-detects which image it's on.

```bash
bash smoke_test.sh          # auto
bash smoke_test.sh art
bash smoke_test.sh train
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
