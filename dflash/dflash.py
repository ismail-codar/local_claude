"""CLI for dflash server — updated for vLLM 0.11."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
ENV_VARS = {
    "APP_DIR": str(SCRIPT_DIR / "dflash"),
    "VENV_DIR": str(SCRIPT_DIR / ".venv"),
    "LOG_DIR": str(SCRIPT_DIR / "logs"),
    "RUN_DIR": str(SCRIPT_DIR / "run"),
    "HF_HOME": str(SCRIPT_DIR / ".cache" / "huggingface"),
}

DEFAULTS = {
    "BASE_MODEL": "Qwen/Qwen3.5-9B",
    "DRAFT_MODEL": "z-lab/Qwen3.5-9B-DFlash",
    "HOST": "0.0.0.0",
    "PORT": "8001",
    "NUM_SPEC_TOKENS": "16",
    # vLLM 0.11 uses enum-style backend names in CLI/docs.
    "ATTENTION_BACKEND": "FLASH_ATTN",
    "MAX_BATCHED_TOKENS": "32768",
    "GPU_MEMORY_UTILIZATION": "0.82",
    "DTYPE": os.getenv("DTYPE", "bfloat16"),
    "TENSOR_PARALLEL_SIZE": "1",
    "MAX_MODEL_LEN": "32768",
    "BLOCK_SIZE": "32",
    "SEED": "42",
}

PID_FILENAME = "vllm_dflash_qwen35_9b.pid"
LOG_FILENAME = "vllm_dflash_qwen35_9b.log"


def _ensure_env():
    """Set up environment variables and directories."""
    for key, path in ENV_VARS.items():
        os.environ[key] = path
        Path(path).mkdir(parents=True, exist_ok=True)

    venv = Path(ENV_VARS["VENV_DIR"])
    if not venv.exists():
        print(f"Virtual environment not found: {venv}")
        print("Run `dflash install` first.")
        sys.exit(1)

    env = {
        **os.environ,
        **ENV_VARS,
        "HF_HOME": ENV_VARS["HF_HOME"],
        "HUGGINGFACE_HUB_CACHE": ENV_VARS["HF_HOME"],
        "VLLM_ALLOW_LONG_MAX_MODEL_LEN": "1",
        "VLLM_WORKER_MULTIPROC_METHOD": "spawn",
        # Keep V1 explicit for vLLM 0.11 behavior consistency.
        "VLLM_USE_V1": "1",
        "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True,max_split_size_mb:256",
        "CUDA_LAUNCH_BLOCKING": "0",
        "NCCL_P2P_DISABLE": "0",
        "TOKENIZERS_PARALLELISM": "false",
    }

    run_dir = Path(ENV_VARS["RUN_DIR"])
    log_dir = Path(ENV_VARS["LOG_DIR"])
    pid_file = run_dir / PID_FILENAME

    return env, run_dir, log_dir, pid_file


def _is_running(pid: str) -> bool:
    return subprocess.run(["kill", "-0", pid], capture_output=True).returncode == 0


def install():
    print("Installing dflash …")
    subprocess.run(["uv", "sync", "--frozen"], cwd=SCRIPT_DIR, check=True)
    print("Done.")


def run():
    """Start the vLLM server with DFlash speculative decoding."""
    env, run_dir, log_dir, pid_file = _ensure_env()
    run_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    if pid_file.exists():
        stored = pid_file.read_text().strip()
        if stored and _is_running(stored):
            print(f"Model already running (PID={stored}).")
            sys.exit(0)
        pid_file.unlink(missing_ok=True)

    def download_if_missing(repo_id: str):
        cache_path = Path(env["HF_HOME"]) / f"models--{repo_id.replace('/', '--')}"
        if cache_path.exists() and any(cache_path.iterdir()):
            print(f"Model cached: {repo_id}")
            return
        print(f"Downloading {repo_id} …")
        subprocess.run(
            [
                "uv",
                "run",
                "python",
                "-c",
                (
                    "from huggingface_hub import snapshot_download; "
                    f"snapshot_download('{repo_id}', resume_download=True)"
                ),
            ],
            env=env,
            check=True,
        )

    download_if_missing(DEFAULTS["BASE_MODEL"])
    download_if_missing(DEFAULTS["DRAFT_MODEL"])

    log_file = log_dir / LOG_FILENAME

    # vLLM 0.11 draft-model speculation config.
    speculative_config = json.dumps(
        {
            "model": DEFAULTS["DRAFT_MODEL"],
            "num_speculative_tokens": int(DEFAULTS["NUM_SPEC_TOKENS"]),
            "method": "draft_model",
        }
    )

    cmd = [
        "uv",
        "run",
        "vllm",
        "serve",
        DEFAULTS["BASE_MODEL"],
        "--host",
        DEFAULTS["HOST"],
        "--port",
        DEFAULTS["PORT"],
        "--seed",
        DEFAULTS["SEED"],
        "--dtype",
        DEFAULTS["DTYPE"],
        "--gpu-memory-utilization",
        DEFAULTS["GPU_MEMORY_UTILIZATION"],
        "--max-num-batched-tokens",
        DEFAULTS["MAX_BATCHED_TOKENS"],
        "--max-model-len",
        DEFAULTS["MAX_MODEL_LEN"],
        "--tensor-parallel-size",
        DEFAULTS["TENSOR_PARALLEL_SIZE"],
        "--block-size",
        DEFAULTS["BLOCK_SIZE"],
        "--attention-backend",
        DEFAULTS["ATTENTION_BACKEND"],
        "--enable-chunked-prefill",
        "--trust-remote-code",
        "--language-model-only",
        "--speculative-config",
        speculative_config,
        "--enforce-eager",
    ]

    print("Starting vLLM server …")
    print(f"Model: {DEFAULTS['BASE_MODEL']}")
    print(f"Draft: {DEFAULTS['DRAFT_MODEL']}")
    print(
        f"GPU memory: {DEFAULTS['GPU_MEMORY_UTILIZATION']} | "
        f"Batch tokens: {DEFAULTS['MAX_BATCHED_TOKENS']}"
    )
    print(
        f"Speculative tokens: {DEFAULTS['NUM_SPEC_TOKENS']} | "
        f"Backend: {DEFAULTS['ATTENTION_BACKEND']}"
    )
    print(f"Log: {log_file}")

    print("cmd: ", " ".join(cmd))

    with open(log_file, "a") as lf:
        proc = subprocess.Popen(
            cmd,
            env=env,
            stdout=lf,
            stderr=lf,
            start_new_session=True,
        )

    pid_file.write_text(str(proc.pid))
    print(f"Model started. PID={proc.pid}")
    print(f"Monitor: tail -f {log_file}")


def stop():
    _, _, _, pid_file = _ensure_env()
    if not pid_file.exists():
        print("No PID file found.")
        return

    pid = pid_file.read_text().strip()
    if not _is_running(pid):
        pid_file.unlink(missing_ok=True)
        print("Process not found. Cleaned.")
        return

    print(f"Stopping server (PID={pid}) …")
    subprocess.run(["kill", "-TERM", pid], check=False)
    for _ in range(30):
        time.sleep(1)
        if not _is_running(pid):
            pid_file.unlink(missing_ok=True)
            print("Stopped.")
            return

    subprocess.run(["kill", "-9", pid], check=False)
    pid_file.unlink(missing_ok=True)
    print("Force killed.")


def status():
    _, _, log_dir, pid_file = _ensure_env()
    if not pid_file.exists():
        print("Status: stopped")
        return

    pid = pid_file.read_text().strip()
    if pid and _is_running(pid):
        print(f"Status: running (PID={pid})")
        print(f"Log: {log_dir / LOG_FILENAME}")
    else:
        pid_file.unlink(missing_ok=True)
        print("Status: stopped (cleaned)")


def main():
    commands = {
        "install": install,
        "run": run,
        "stop": stop,
        "status": status,
    }
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        print(f"Usage: dflash <{'|'.join(commands)}>")
        sys.exit(1)
    commands[sys.argv[1]]()


if __name__ == "__main__":
    main()
