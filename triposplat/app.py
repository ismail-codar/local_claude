"""TripoSplat – gradio.Server with custom frontend.
Usage: python app.py
"""
import base64
import os
import subprocess
import tempfile
import time
from pathlib import Path
from uuid import uuid4

import torch
from PIL import Image
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
import gradio as gr
from gradio import Server
from gradio.data_classes import FileData

from triposplat import TripoSplatPipeline
import example_inputs_b64 as _b64

# ----------------------------------------------------------------------------
# GPU runtime selection
# ----------------------------------------------------------------------------
# HuggingFace ZeroGPU ortamında `spaces.GPU` dekoratörü GPU'yu talep eder ve
# fonksiyonu ayrı bir process'te çalıştırır. Yerel GPU'da bu gereksizdir; paket
# kurulu değilse dekoratörü no-op'a düşürüp fonksiyonu doğrudan çalıştırırız.
try:
    import spaces  # type: ignore

    _gpu = spaces.GPU
except ImportError:  # yerel GPU / ZeroGPU yok
    def _gpu(func=None, **_kwargs):
        if func is None:
            return lambda f: f
        return func

# ----------------------------------------------------------------------------
# Download checkpoints from HuggingFace Hub (VAST-AI/TripoSplat)
# ----------------------------------------------------------------------------

subprocess.run(
    [
        "hf", "download",
        "VAST-AI/TripoSplat",
        "--local-dir", "ckpts"
    ],
    check=True,
)

# ----------------------------------------------------------------------------
# Pipeline (loaded once at startup)
# ----------------------------------------------------------------------------

PIPE = TripoSplatPipeline(
    ckpt_path              = "ckpts/diffusion_models/triposplat_fp16.safetensors",
    decoder_path           = "ckpts/vae/triposplat_vae_decoder_fp16.safetensors",
    dinov3_path            = "ckpts/clip_vision/dino_v3_vit_h.safetensors",
    flux2_vae_encoder_path = "ckpts/vae/flux2-vae.safetensors",
    rmbg_path              = "ckpts/background_removal/birefnet.safetensors",
    device                 = "cuda",
)

OUT_ROOT = Path("gradio_outputs").resolve()
OUT_ROOT.mkdir(parents=True, exist_ok=True)

# Decode example images from base64 into a persistent temp directory so that
# the custom frontend can serve them via FastAPI routes.
_EXAMPLES_TMPDIR = tempfile.mkdtemp(prefix="triposplat_examples_")


def _write_example(varname: str, filename: str) -> str:
    path = Path(_EXAMPLES_TMPDIR) / filename
    path.write_bytes(base64.b64decode(getattr(_b64, varname)))
    return str(path)


EXAMPLES = [
    {"name": "Creature Butterfly",  "file": _write_example("CREATURE_BUTTERFLY",   "creature_butterfly.webp")},
    {"name": "Building Stone House","file": _write_example("BUILDING_STONE_HOUSE", "building_stone_house.webp")},
    {"name": "Vehicle Pirate Ship", "file": _write_example("VEHICLE_PIRATE_SHIP",  "vehicle_pirate_ship.webp")},
    {"name": "Plant Water Lily",    "file": _write_example("PLANT_WATER_LILY",     "plant_water_lily.webp")},
]

# ----------------------------------------------------------------------------
# gradio.Server
# ----------------------------------------------------------------------------

app = Server()


# ---- Static pages ----------------------------------------------------------

@app.get("/")
async def homepage():
    """Serve the custom frontend."""
    html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
    with open(html_path, "r", encoding="utf-8") as f:
        return HTMLResponse(f.read())


@app.get("/viewer")
async def viewer_page():
    """Serve the Spark.js 3D viewer (loaded inside an iframe)."""
    viewer_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "static", "viewer", "viewer.html",
    )
    with open(viewer_path, "r", encoding="utf-8") as f:
        return HTMLResponse(f.read())


# ---- Example images --------------------------------------------------------

@app.get("/api/examples")
async def get_examples():
    """Return a JSON list of example images the frontend can display."""
    return JSONResponse([
        {"name": ex["name"], "url": f"/api/example/{i}"}
        for i, ex in enumerate(EXAMPLES)
    ])


@app.get("/api/example/{idx}")
async def get_example(idx: int):
    """Serve an individual example image by index."""
    if 0 <= idx < len(EXAMPLES):
        return FileResponse(EXAMPLES[idx]["file"], media_type="image/webp")
    return JSONResponse({"error": "not found"}, status_code=404)


# ----------------------------------------------------------------------------
# GPU pipeline helper
# ----------------------------------------------------------------------------

@_gpu
def _run_pipeline(pil_image, seed, steps, guidance_scale, num_gaussians,
                  out_dir, output_format, progress=None):
    """Run the full pipeline (preprocess → encode → sample → decode → save)
    in a single GPU acquisition.

    All file I/O happens here so the unpicklable Gaussian object never
    crosses the ZeroGPU multiprocessing boundary.

    ``progress`` is an optional ``gradio.Progress`` tracker. When supplied,
    the bar tracks the sampling loop only: stages before sampling (preprocess,
    encode) report 0% and stages after it (decode, save) report 100%, so the
    bar fills 0% → 100% across the sampling steps via a per-step callback.
    """
    def _report(frac, desc):
        if progress is not None:
            progress(frac, desc=desc)

    t0 = time.time()

    _report(0.0, "Preprocessing image")
    prepared = PIPE.preprocess_image(pil_image)

    _report(0.0, "Encoding image")
    gen = torch.Generator(device=PIPE._device).manual_seed(int(seed))
    cond = PIPE.encode_image(prepared, generator=gen)

    total_steps = int(steps)

    def _on_step(step, total):
        _report(step / total, f"Sampling · step {step}/{total}")

    out = PIPE.sample_latent(
        cond,
        steps=total_steps,
        guidance_scale=float(guidance_scale),
        generator=gen,
        show_progress=True,
        callback=_on_step,
    )

    _report(1.0, "Decoding gaussians")
    gaussian = PIPE.decode_latent(out["latent"], num_gaussians=int(num_gaussians))
    gen_dt = time.time() - t0

    _report(1.0, "Saving output")

    # Save preprocessed image
    prep_path = out_dir / "preprocessed.png"
    prepared.save(str(prep_path))

    # Save PLY (always needed for the viewer)
    ply_path = out_dir / "splat.ply"
    gaussian.save_ply(str(ply_path))

    # Save in the requested download format
    fmt = output_format.lower()
    if fmt == "splat":
        download_path = out_dir / "splat.splat"
        gaussian.save_splat(str(download_path))
    else:
        download_path = ply_path

    n_gaussians = gaussian.get_xyz.shape[0]

    _report(1.0, "Done")

    # Return only picklable primitives / paths
    return str(prep_path), str(ply_path), str(download_path), n_gaussians, gen_dt


# ----------------------------------------------------------------------------
# Main API endpoint  (queued via Gradio's engine)
# ----------------------------------------------------------------------------

@app.api()
def generate(
    image: FileData,
    seed: int = 42,
    steps: int = 20,
    guidance_scale: float = 3.0,
    num_gaussians: int = 262144,
    output_format: str = "ply",
) -> tuple[FileData, FileData, FileData, str]:
    """Generate 3D Gaussians from an input image.

    Returns (preprocessed_image, ply_file, download_file, info_string).
    The frontend receives these as result.data[0..3].

    Sampling progress is streamed to the client over Gradio's SSE queue via a
    ``gr.Progress`` tracker. The tracker is created inside the function body
    (rather than declared as a parameter) because ``@app.api()`` derives the
    endpoint's input schema from the signature and would otherwise treat a
    ``progress`` parameter as a required API input.
    """
    pil_image = Image.open(image["path"]).convert("RGBA")

    progress = gr.Progress()

    out_dir = OUT_ROOT / uuid4().hex[:12]
    out_dir.mkdir(parents=True, exist_ok=True)

    prep_path, ply_path, download_path, n_gaussians, gen_dt = _run_pipeline(
        pil_image, seed, steps, guidance_scale, num_gaussians,
        out_dir, output_format, progress=progress,
    )

    info = (
        f"{n_gaussians:,} gaussians  ·  "
        f"generation: {gen_dt:.1f}s  ·  saved: {Path(download_path).name}"
    )

    return (
        FileData(path=prep_path),
        FileData(path=ply_path),
        FileData(path=download_path),
        info,
    )


# ----------------------------------------------------------------------------
# Launch
# ----------------------------------------------------------------------------

if __name__ == "__main__":
    app.launch(show_error=True)
