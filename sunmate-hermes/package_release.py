#!/usr/bin/env python3
"""Build the manifest and self-contained offline packages from known inputs."""
import hashlib
import json
from pathlib import Path
import tarfile
import zipfile
import argparse
import sys
from installer import VERSION, SKILLS, ARCHIVE_FILES

ROOT = Path(__file__).resolve().parent


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest-only', action='store_true')
    args = parser.parse_args([] if argv is None else argv)
    names = ["installer.py", "setup_hermes.sh", "install_to_hermes.sh", "README.md", "compatibility.json"]
    names += list(ARCHIVE_FILES)
    names += [f"skills/{skill}/{leaf}" for skill in SKILLS for leaf in ("SKILL.md", "references/data-contract.md")]
    contracts = {(ROOT / f"skills/{skill}/references/data-contract.md").read_bytes() for skill in SKILLS}
    if len(contracts) != 1:
        raise SystemExit("数据契约存在不同副本，请先统一后再打包。")
    files = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sorted(names)}
    compatibility = json.loads((ROOT / "compatibility.json").read_text(encoding="utf-8"))
    if compatibility.get("version") != VERSION or compatibility.get("product") != "sunmate-hermes":
        raise SystemExit("App兼容声明与安装器版本不一致。")
    manifest = {"product": "sunmate-hermes", "version": VERSION, "files": files}
    manifest_path = ROOT / "manifest.json"
    rendered = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    if not manifest_path.exists() or manifest_path.read_text(encoding="utf-8") != rendered:
        manifest_path.write_text(rendered, encoding="utf-8")
    if args.manifest_only:
        print('仅更新本地源码清单，未生成或覆盖安装包。')
        return
    output = ROOT.parent / "build_output" / "hermes-release"
    output.mkdir(parents=True, exist_ok=True)
    all_files = [*sorted(names), "manifest.json"]
    archives = []
    zip_path = output / f"sunmate-hermes-{VERSION}.zip"
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in all_files:
            archive.write(ROOT / name, "sunmate-hermes/" + name)
    archives.append(zip_path)
    tar_path = output / f"sunmate-hermes-{VERSION}.tar.gz"
    with tarfile.open(tar_path, "w:gz") as archive:
        for name in all_files:
            archive.add(ROOT / name, arcname="sunmate-hermes/" + name, recursive=False)
    archives.append(tar_path)
    checksums = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in archives)
    (output / f"SHA256SUMS-{VERSION}").write_text(checksums, encoding="utf-8")
    print(f"已更新 manifest.json，生成 {len(archives)} 个完整离线包：{output}")


if __name__ == "__main__":
    main(sys.argv[1:])
