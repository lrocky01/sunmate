#!/usr/bin/env bash
# Local checkout, offline package and curl | bash share this entry.
set -euo pipefail

if ! command -v hermes >/dev/null 2>&1; then
  echo "错误：请先安装 Hermes 并将 hermes 命令加入 PATH；SunMate 不安装 Hermes。" >&2
  exit 1
fi
PYTHON_BIN="${SUNMATE_PYTHON:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "错误：需要 Python 3.9+，可用 SUNMATE_PYTHON 指向已有解释器。" >&2
  exit 1
fi
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  if [[ -f "$SCRIPT_DIR/installer.py" && -f "$SCRIPT_DIR/manifest.json" ]]; then
    exec "$PYTHON_BIN" "$SCRIPT_DIR/installer.py" "$@"
  fi
fi

# Resolve main once; all files must come from the same commit. Download and hash
# every file before running the installer. No installer input comes from stdin.
"$PYTHON_BIN" - "$@" <<'PY'
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

if sys.version_info < (3, 9):
    raise SystemExit("错误：需要 Python 3.9+。")
REPOSITORY = "lrocky01/sunmate"
MAX_FILE_BYTES = 2 * 1024 * 1024


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "SunMate-Installer/2"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                data = response.read(MAX_FILE_BYTES + 1)
                if len(data) > MAX_FILE_BYTES:
                    raise ValueError("下载文件超过大小限制")
                return data
        except urllib.error.HTTPError as error:
            if error.code < 500 and error.code != 429:
                raise ValueError(f"下载失败 HTTP {error.code}；请检查该版本是否已发布") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            pass
        if attempt < 2:
            time.sleep(attempt + 1)
    raise ValueError("下载失败，已重试三次；可改用完整离线安装包")


def main():
    try:
        result = subprocess.run(["hermes", "--version"], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError("Hermes 不可运行或超时；未下载或安装任何资源") from None
    if result.returncode:
        raise ValueError("Hermes 不可运行；未下载或安装任何资源")
    ref = os.environ.get("SUNMATE_REF", "main")
    if ref != "main" and not re.fullmatch(r"[0-9a-fA-F]{40}", ref):
        raise ValueError("SUNMATE_REF 仅接受 main 或完整的 Git commit SHA")
    if ref == "main":
        ref = json.loads(download(f"https://api.github.com/repos/{REPOSITORY}/commits/main"))["sha"]
    if not re.fullmatch(r"[0-9a-fA-F]{40}", ref):
        raise ValueError("无法确认安装版本的 commit SHA")
    print(f"正在下载 SunMate 接入包，固定版本 {ref[:12]}…", flush=True)
    base = f"https://raw.githubusercontent.com/{REPOSITORY}/{ref}/sunmate-hermes"
    manifest_bytes = download(f"{base}/manifest.json")
    manifest = json.loads(manifest_bytes)
    files = manifest.get("files", {})
    if manifest.get("product") != "sunmate-hermes" or not isinstance(files, dict) or not 1 <= len(files) <= 50:
        raise ValueError("安装清单无效")
    if "installer.py" not in files:
        raise ValueError("安装清单缺少 installer.py")
    for name, digest in files.items():
        path = PurePosixPath(name)
        if path.is_absolute() or not path.parts or any(p in ("..", ".") for p in path.parts) or "\\" in name:
            raise ValueError("安装清单包含无效路径")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("安装清单包含无效 SHA-256")
    with tempfile.TemporaryDirectory(prefix="sunmate-install-") as temporary:
        root = Path(temporary)
        def fetch(item):
            name, expected = item
            data = download(f"{base}/{name}")
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError(f"完整性校验失败：{name}")
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(fetch, files.items()))
        (root / "manifest.json").write_bytes(manifest_bytes)
        print("下载与 SHA-256 校验通过。", flush=True)
        return subprocess.run([sys.executable, str(root / "installer.py"), *sys.argv[1:]]).returncode


try:
    sys.exit(main())
except (ValueError, KeyError, TypeError, OSError) as error:
    print(f"错误：{error}", file=sys.stderr)
    sys.exit(1)
PY
