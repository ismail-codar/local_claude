"""CLI for dflash server."""

import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

SCRIPT_DIR = Path(__file__).parent.resolve()
ENV_VARS = {
    "APP_DIR": str(SCRIPT_DIR / "dflash"),
    "VENV_DIR": str(SCRIPT_DIR / ".venv"),
    "LOG_DIR": str(SCRIPT_DIR / "logs"),
    "RUN_DIR": str(SCRIPT_DIR / "run"),
    "HF_HOME": str(SCRIPT_DIR / ".cache" / "huggingface"),
}

DEFAULTS = {
    "BASE_MODEL": "Qwen/Qwen3.5-35B-A3B",
    "DRAFT_MODEL": "z-lab/Qwen3.5-35B-A3B-DFlash",
    "HOST": "0.0.0.0",
    "PORT": "8000",
    "NUM_SPEC_TOKENS": "16",
    "ATTENTION_BACKEND": "flash_attn",
    "MAX_BATCHED_TOKENS": "32768",
}


def _ensure_env() -> tuple[dict[str, str], Path, Path, Path, Path, Path]:
    """Ensure environment directories and venv."""
    for key, path in ENV_VARS.items():
        os.environ[key] = path
        Path(path).parent.mkdir(parents=True, exist_ok=True)

    venv = Path(ENV_VARS["VENV_DIR"])
    if not venv.exists():
        print(f"Virtual environment not found: {venv}")
        print("Run `dflash install` first")
        sys.exit(1)

    return (
        {**os.environ, **ENV_VARS, "HF_HOME": ENV_VARS["HF_HOME"]},
        Path(ENV_VARS["RUN_DIR"]),
        Path(ENV_VARS["LOG_DIR"]),
        venv / "bin" / "activate",
        Path(ENV_VARS["RUN_DIR"]) / "vllm_dflash_qwen35_35b_a3b.pid",
    )


def install():
    """Install the project."""
    print("Installing dflash...")
    subprocess.run(["uv", "sync", "--frozen"], cwd=SCRIPT_DIR, check=True)
    print("Installed")


def run():
    """Start the dflash server."""
    env, run_dir, log_dir, _, pid_file = _ensure_env()

    run_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    if pid_file.exists():
        if subprocess.run(["kill", "-0", pid_file.read_text().strip()],
                         capture_output=True).returncode == 0:
            print("Model already running")
            sys.exit(0)
        pid_file.unlink(missing_ok=True)

    os.environ.update({
        "HF_HOME": env["HF_HOME"],
        "HUGGINGFACE_HUB_CACHE": env["HF_HOME"],
        "TRANSFORMERS_CACHE": env["HF_HOME"],
        "VLLM_ALLOW_LONG_MAX_MODEL_LEN": "1",
    })

    base_model = DEFAULTS["BASE_MODEL"]
    draft_model = DEFAULTS["DRAFT_MODEL"]
    num_spec_tokens = DEFAULTS["NUM_SPEC_TOKENS"]
    attention_backend = DEFAULTS["ATTENTION_BACKEND"]
    max_batched_tokens = DEFAULTS["MAX_BATCHED_TOKENS"]

    def download_if_missing(repo_id: str) -> None:
        hint = f"{env['HF_HOME']}/models--{repo_id.replace('/', '--')}"
        if Path(hint).exists() and any(Path(hint).iterdir()):
            return
        subprocess.run(
            ["uv", "run", "python", "-c",
             f"from huggingface_hub import snapshot_download; "
             f"snapshot_download('{repo_id}', resume_download=True, "
             f"local_dir=None, local_dir_use_symlinks=False)"],
            env=env, check=True)

    download_if_missing(base_model)
    download_if_missing(draft_model)

    log_file = str(log_dir / "vllm_dflash_qwen35_35b_a3b.log")

    cmd = [
        "uv", "run", "vllm", "serve", base_model,
        "--host", DEFAULTS["HOST"],
        "--port", DEFAULTS["PORT"],
        "--speculative-config",
        f'{{"method": "dflash", "model": "{draft_model}", '
        f'"num_speculative_tokens": {num_spec_tokens}}}',
        "--attention-backend", attention_backend,
        "--max-num-batched-tokens", max_batched_tokens,
    ]

    result = subprocess.run(
        cmd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    pid = str(result.returncode)
    if pid != "0":
        print(f"Failed to start model. Log: {log_file}")
        sys.exit(1)

    print(f"Model started. PID={pid}")
    print(f"Log: {log_file}")


def stop():
    """Stop the dflash server."""
    _, _, _, _, pid_file = _ensure_env()

    if not pid_file.exists():
        print("No PID file found")
        return

    pid = pid_file.read_text().strip()
    if not pid or not subprocess.run(
        ["kill", "-0", pid],
        capture_output=True,
    ).returncode == 0:
        if pid:
            pid_file.unlink()
        print("Empty PID file cleaned")
        return

    subprocess.run(["kill", pid])
    for _ in range(20):
        if not subprocess.run(
            ["kill", "-0", pid],
            capture_output=True,
        ).returncode == 0:
            pid_file.unlink()
            print(f"Model stopped. PID={pid}")
            return
        subprocess.run(["sleep", "1"])

    subprocess.run(["kill", "-9", pid], capture_output=True)
    pid_file.unlink()
    print(f"Model stopped. PID={pid}")


def main():
    """CLI entrypoint."""
    if len(sys.argv) < 2:
        print("Usage: dflash <install|run|stop>")
        sys.exit(1)

    command = sys.argv[1].lower()
    if command == "install":
        install()
    elif command == "run":
        run()
    elif command == "stop":
        stop()
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
