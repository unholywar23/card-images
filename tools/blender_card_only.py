"""blender_card_only.py - paste-in / import for EVERY Blender job on a rented card. Forces the render onto the NVIDIA
card only (OptiX), never the processor. A mixed render (every device on, CPU denoiser) measured ~6.5 s a frame with
the card mostly idle; card only, OptiX: about 1-2 s a frame.

Use inside a Blender script, after the scene exists:
    import sys; sys.path.insert(0, "/workspace/tools"); from blender_card_only import card_only; card_only(bpy.context.scene)
It raises (the job stops) if no NVIDIA card is found, so a render can never fall back to the processor quietly."""
import bpy


def card_only(scene, samples=None):
    prefs = bpy.context.preferences.addons["cycles"].preferences
    kind = None
    for k in ("OPTIX", "CUDA"):
        try:
            prefs.compute_device_type = k
            prefs.get_devices()
            if any(d.type == k for d in prefs.devices):
                kind = k
                break
        except TypeError:
            continue
    if kind is None:
        raise RuntimeError("no NVIDIA card visible to Blender: refusing to render on the processor")
    used = []
    for d in prefs.devices:
        d.use = (d.type == kind)          # the card only, never the processor
        if d.use:
            used.append(d.name)
    scene.render.engine = "CYCLES"
    scene.cycles.device = "GPU"
    if kind == "OPTIX":
        scene.cycles.denoiser = "OPTIX"   # denoise on the card too
    scene.render.use_overwrite = False    # a restarted render keeps the frames it already made
    scene.render.use_persistent_data = True   # keep the scene on the card between frames (no re-upload every frame)
    if samples:
        scene.cycles.samples = samples
    print("CARD ONLY: %s on %s" % (kind, ", ".join(used)))
    return kind, used
