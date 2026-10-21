#!/usr/bin/env python3
"""Install owned skills and verify an existing native Hermes API; no server code."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

VERSION = "2.2.0"
SKILLS = (
    "lifelog-daily-review", "meeting-diarize-process", "notification-digest",
    "context-memory-query", "sunmate-doctor",
)
ARCHIVE_FILES = ("ARCHIVE.md", "prepare_archive.py", *(
    "archive_runtime/" + name for name in ("__init__.py", "store.py", "service.py", "native_api.py", "plugin.py", "plugin.yaml")))
ROOT = Path(__file__).resolve().parent
MAX_RESPONSE = 2 * 1024 * 1024


class InstallError(Exception):
    pass


def say(message):
    print(message, flush=True)


def run_hermes(binary, arguments, home=None, timeout=20):
    env = os.environ.copy()
    if home is not None:
        env["HERMES_HOME"] = str(home)
        env.pop("HERMES_PROFILE", None)
    try:
        result = subprocess.run([binary, *arguments], capture_output=True, text=True,
                                env=env, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise InstallError("Hermes 命令不可运行或超时；请先检查 hermes --version / gateway status。") from None
    if result.returncode:
        # Hermes diagnostics can contain credentials. Do not dump captured output.
        raise InstallError("Hermes 命令失败；请自行检查对应 profile 的 gateway status，勿分享密钥或原始日志。")
    return result.stdout


def select_home(args):
    provided = args.hermes_home or os.environ.get("HERMES_HOME")
    home = Path(provided).expanduser() if provided else Path.home() / ".hermes"
    home = home.resolve()
    root = home.parent.parent if home.parent.name == "profiles" else home
    profiles_root = root / "profiles"
    names = sorted(p.name for p in profiles_root.iterdir() if p.is_dir()) if profiles_root.is_dir() else []
    say("可用 profile：" + ", ".join(["default", *names]))
    profile = args.profile or os.environ.get("HERMES_PROFILE")
    if profile:
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", profile):
            raise InstallError("profile 名称无效。")
        home = root if profile == "default" else profiles_root / profile
        if provided and Path(provided).expanduser().resolve().parent.name == "profiles" and home != Path(provided).expanduser().resolve():
            raise InstallError("HERMES_HOME 与 --profile 指向不同 profile；请只保留一致的选择。")
    elif not provided:
        active = root / "active_profile"
        if active.is_file():
            profile = active.read_text(encoding="utf-8").strip()
            if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", profile):
                raise InstallError("active_profile 无效；请显式指定 --profile。")
            home = root if profile == "default" else profiles_root / profile
        elif names:
            raise InstallError("检测到多个 profile；请用 --profile NAME（或 default）选择，未写入任何文件。")
    if not home.is_dir() or not any((home / name).is_file() for name in ("config.yaml", ".env")):
        raise InstallError("所选 Hermes 配置目录不存在或未初始化；请先完成 Hermes 自身配置。")
    say(f"目标 Hermes 配置目录：{home}")
    return home


def read_yaml(path, binary):
    if not path.exists():
        return {}
    content = path.read_text(encoding="utf-8")
    try:
        import yaml
        result = yaml.safe_load(content) or {}
    except ImportError:
        # Skill installation adds no Python packages. Reuse the existing Hermes
        # interpreter for YAML decoding if the bootstrap Python has no PyYAML.
        candidates = []
        entry = Path(binary).resolve()
        for _ in range(5):
            if not entry.is_file():
                break
            text = entry.read_text(encoding="utf-8", errors="replace")[:8192]
            first = text.splitlines()[0] if text else ""
            if first.startswith("#!") and "python" in first:
                parts = shlex.split(first[2:])
                if parts and Path(parts[0]).is_absolute() and Path(parts[0]).name != "env":
                    candidates.append(parts[0])
                break
            match = re.search(r'^\s*exec\s+"([^"\n]+)"', text, re.M)
            if not match:
                break
            entry = Path(match.group(1))
        candidates.extend(str(entry.parent / name) for name in ("python", "python3"))
        result = None
        for candidate in dict.fromkeys(candidates):
            if not Path(candidate).is_file() or not os.access(candidate, os.X_OK):
                continue
            try:
                decoded = subprocess.run(
                    [candidate, "-c", "import json,sys,yaml; print(json.dumps(yaml.safe_load(sys.stdin.read()) or {}))"],
                    input=content, capture_output=True, text=True, timeout=10)
                if decoded.returncode == 0:
                    result = json.loads(decoded.stdout)
                    break
            except (OSError, ValueError, subprocess.TimeoutExpired):
                continue
        if result is None:
            raise InstallError("无法解析 YAML：请用 SUNMATE_PYTHON 指向已有 Hermes Python；不自动安装系统依赖。") from None
    except Exception:
        raise InstallError("Hermes config.yaml 无法解析；请修复配置后重试。") from None
    if not isinstance(result, dict):
        raise InstallError("Hermes config.yaml 顶层必须是映射。")
    return result


def read_api_env(path):
    values = {}
    if not path.exists():
        return values
    # Never source .env as shell code. Only parse API_SERVER_* literals; do not
    # expose unrelated provider credentials or evaluate command substitutions.
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\s*(?:export\s+)?(API_SERVER_[A-Z_]+)\s*=\s*(.*)$", line)
        if not match:
            continue
        name, raw = match.groups()
        try:
            parts = shlex.split(raw, comments=True, posix=True)
        except ValueError:
            raise InstallError(f"{name} 的配置不是有效字面量。") from None
        if len(parts) > 1 or (parts and "$" in parts[0]):
            raise InstallError(f"{name} 使用了不支持的插值/表达式；请在运行环境中提供实际值。")
        values[name] = parts[0] if parts else ""
    return values


def native_settings(home, binary):
    config = read_yaml(home / "config.yaml", binary)
    gateway = config.get("gateway") or {}
    if not isinstance(gateway, dict):
        raise InstallError("Hermes gateway 配置不是映射。")
    api = gateway.get("api_server") or {}
    platforms = gateway.get("platforms") or {}
    if not isinstance(api, dict) or not isinstance(platforms, dict):
        raise InstallError("Hermes API 配置不是映射。")
    platform = platforms.get("api_server") or {}
    if not isinstance(platform, dict):
        raise InstallError("Hermes api_server platform 配置不是映射。")
    extra = platform.get("extra") or {}
    if not isinstance(extra, dict):
        raise InstallError("Hermes api_server extra 配置不是映射。")
    api = {**api, **platform, **extra}
    env = read_api_env(home / ".env")
    env.update({k: v for k, v in os.environ.items() if k.startswith("API_SERVER_")})
    def setting(name, fallback):
        return env.get("API_SERVER_" + name.upper(), api.get(name, fallback))
    host = str(setting("host", "127.0.0.1"))
    try:
        port = int(setting("port", 8642))
        if not 1 <= port <= 65535:
            raise ValueError()
    except (ValueError, TypeError):
        raise InstallError("Hermes API 端口无效。") from None
    key_value = setting("key", "")
    if not isinstance(key_value, str):
        raise InstallError("Hermes API_SERVER_KEY 必须是字符串。")
    key = key_value
    if len(key.strip()) < 16 or any(ord(c) < 32 for c in key):
        raise InstallError("未找到有效的 Hermes API_SERVER_KEY（至少 16 字符）；不生成、不打印、不修改密钥。")
    enabled = str(setting("enabled", bool(key))).lower() in ("true", "yes", "1")
    if not enabled:
        raise InstallError("Hermes 原生 API 未启用；请按官方文档启用 API_SERVER_ENABLED 后重试。")
    local_host = "127.0.0.1" if host == "0.0.0.0" else "::1" if host in ("::", "[::]") else host
    if ":" in local_host and not local_host.startswith("["):
        local_host = f"[{local_host}]"
    return {"url": f"http://{local_host}:{port}/v1", "key": key, "host": host}


def normalize_url(value):
    value = value.rstrip("/")
    if any(ord(c) <= 32 or ord(c) == 127 for c in value):
        raise InstallError("端点包含空白或控制字符。")
    try:
        parsed = urllib.parse.urlsplit(value)
        parsed.port
    except ValueError:
        raise InstallError("端点主机名或端口无效。") from None
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise InstallError("端点必须是无凭据、无查询参数的 HTTP(S) 地址，并以 /v1 结尾。")
    if not parsed.path.endswith("/v1"):
        raise InstallError("端点应包含 /v1；多 profile 路由请保留完整路径前缀。")
    loopback = parsed.hostname == "localhost"
    try:
        loopback = loopback or ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        pass
    if parsed.scheme == "http" and not loopback:
        raise InstallError("非回环地址必须使用 HTTPS；请通过 TLS 反代/VPN 安全接入。")
    return value, loopback


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api_request(base, path, key, payload=None, timeout=10):
    headers = {"Accept": "application/json"}
    if key is not None:
        headers["Authorization"] = "Bearer " + key
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(base + path, data=data, headers=headers)
    try:
        with opener.open(request, timeout=timeout) as response:
            body = response.read(MAX_RESPONSE + 1)
            if len(body) > MAX_RESPONSE:
                raise InstallError("API 响应超过自检大小上限。")
            try:
                return response.status, json.loads(body)
            except (ValueError, UnicodeError):
                raise InstallError("API 未返回有效 JSON，可能连接到了网页或错误的反代路径。") from None
    except urllib.error.HTTPError as error:
        return error.code, None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise InstallError("无法连接 Hermes 原生 API，或请求超时；请检查监听、证书和 gateway status。") from None


def check_api(base, key, timeout):
    # Fail closed before any inference if auth is missing or silently ignored.
    for credential in (None, "sunmate-invalid-" + uuid.uuid4().hex):
        status, _ = api_request(base, "/models", credential)
        if status not in (401, 403):
            raise InstallError("未通过鉴权反向检查：缺失/错误 Token 必须被拒绝，不能只看 HTTP 200。")
    status, models = api_request(base, "/models", key)
    if status in (401, 403):
        raise InstallError("Hermes 鉴权失败（401/403）；请核对所选 profile 的 API_SERVER_KEY。")
    if status != 200 or not isinstance(models, dict) or not isinstance(models.get("data"), list):
        raise InstallError(f"Hermes 模型发现失败（HTTP {status}）。")
    model_ids = [m.get("id") for m in models["data"] if isinstance(m, dict) and isinstance(m.get("id"), str) and m["id"]]
    if not model_ids:
        raise InstallError("Hermes 未返回可用模型。")
    challenge = "SUNMATE_" + uuid.uuid4().hex
    payload = {
        "model": model_ids[0], "stream": False,
        "messages": [{"role": "user", "content": (
            "这是连接自检。不要调用工具，不要读取或写入记忆，不执行任何业务操作。"
            "请仅原样回复下面的随机校验文本：" + challenge)}],
    }
    say("正在进行一次真实推理自检（可能产生少量模型费用，最长等待 %s 秒）…" % timeout)
    status, reply = api_request(base, "/chat/completions", key, payload, timeout)
    try:
        choice = reply["choices"][0]
        content = choice["message"]["content"]
        passed = status == 200 and not reply.get("error") and choice["finish_reason"] == "stop" and isinstance(content, str) and challenge in content
    except (TypeError, KeyError, IndexError):
        passed = False
    if not passed:
        raise InstallError(f"真实推理自检未通过（HTTP {status}）；安装器不会将空回复、模板或错误当作成功。")
    return model_ids[0]


def validate_sse(lines, challenge):
    """Validate a single OpenAI-compatible turn without logging response data."""
    event, data, text = "", [], []
    stopped = False
    progress = 0
    for line in lines:
        if line.startswith(":"):
            continue
        if line:
            field, _, value = line.partition(":")
            value = value[1:] if value.startswith(" ") else value
            if field == "event":
                event = value
            elif field == "data":
                data.append(value)
            continue
        body = "\n".join(data)
        name, event, data = event, "", []
        if not body:
            continue
        if body.strip() == "[DONE]":
            if not stopped or challenge not in "".join(text):
                raise InstallError("SSE 提前结束或缺少完整校验答复；未把前置说明当作最终回复。")
            return {"tool_progress_events": progress}
        try:
            item = json.loads(body)
        except (ValueError, TypeError):
            raise InstallError("SSE 包含无效 JSON；未通过流式检查。") from None
        if not isinstance(item, dict) or item.get("error") is not None or name in ("error", "hermes.error"):
            raise InstallError("SSE 报告错误；未通过流式检查。")
        flags = item.get("hermes")
        if isinstance(flags, dict) and (flags.get("completed") is False or
                flags.get("partial") is True or flags.get("failed") is True):
            raise InstallError("Hermes 报告流式回复未完成；未把部分内容当作成功。")
        if name == "hermes.tool.progress":
            progress += 1
            continue
        if name == "hermes.status":
            continue
        if name == "approval.request":
            raise InstallError("流式自检遇到服务端确认请求，请在服务端核对；未自动批准或重试。")
        choices = item.get("choices")
        if not isinstance(choices, list):
            raise InstallError("SSE 内容帧结构无效。")
        for choice in choices:
            if not isinstance(choice, dict):
                raise InstallError("SSE 内容帧结构无效。")
            if choice.get("index", 0) != 0:
                continue
            delta = choice.get("delta", {})
            if not isinstance(delta, dict):
                raise InstallError("SSE 内容帧结构无效。")
            value = delta.get("content")
            if value is not None:
                if not isinstance(value, str) or (value and stopped):
                    raise InstallError("SSE 正文或结束顺序无效。")
                text.append(value)
            reason = choice.get("finish_reason")
            if reason == "stop":
                stopped = True
            elif reason not in (None, "tool_calls", "function_call"):
                raise InstallError("SSE 未正常完成（失败、取消或达到输出限制）。")
    raise InstallError("SSE 连接结束但未收到完整结束标记；未通过流式检查。")


def check_stream(base, key, model, timeout):
    challenge = "SUNMATE_STREAM_" + uuid.uuid4().hex
    payload = {"model": model, "stream": True, "messages": [{"role": "user", "content":
        "这是流式连接自检。不要调用工具，不读写记忆，不处理业务。请仅原样回复：" + challenge}]}
    request = urllib.request.Request(base + "/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"), headers={
            "Authorization": "Bearer " + key, "Content-Type": "application/json",
            "Accept": "text/event-stream"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    say("正在进行一次额外的真实 SSE 自检（可能产生模型费用，不自动重试）…")
    deadline = time.monotonic() + timeout
    try:
        with opener.open(request, timeout=timeout) as response:
            if response.status != 200 or response.headers.get_content_type() != "text/event-stream":
                raise InstallError("SSE 未返回 HTTP 200 的 text/event-stream。")
            def lines():
                total = 0
                while True:
                    if time.monotonic() >= deadline:
                        raise InstallError("SSE 自检超时，未自动重发请求。")
                    raw = response.readline(MAX_RESPONSE + 1)
                    if not raw:
                        return
                    total += len(raw)
                    if total > MAX_RESPONSE:
                        raise InstallError("SSE 响应超过自检大小上限。")
                    yield raw.decode("utf-8").rstrip("\r\n")
            result = validate_sse(lines(), challenge)
    except urllib.error.HTTPError as error:
        raise InstallError(f"SSE 请求未通过（HTTP {error.code}）；未跟随重定向或重发。") from None
    except (urllib.error.URLError, TimeoutError, OSError, UnicodeError):
        raise InstallError("SSE 连接、编码或读取失败；未自动重发，不输出响应正文。") from None
    say("SSE 正文、finish_reason=stop 和 [DONE] 已验证；工具进度事件 %s 条。" % result["tool_progress_events"])
    say("本次只做随机文本回显，没有验证天气查询等真实工具执行。")
    return result


def report_app_capabilities(stream_checked=False):
    say("App 适配：SunMate 1.0.33+34；兼容会议/随身文字请求及 sunmate.data.v1 通知请求。")
    say("能力边界：支持显式开启通知、会议/随身转写和结果同步；各类自动同步默认关闭，历史补传需选择范围。")
    say("会议音频由 App 发往私有 ASR；本包不接管 ASR、蓝牙、卡片密钥或手机存储。")
    say("三类报告返回 Markdown，由 App 保存；业务效果及手机侧尚未验证。")
    say("资料归档需另行准备并启用本包原生插件，核对 /sunmate/v1；安装技能不等于接收和查询工具已启用。不自动写长期记忆。")
    if not stream_checked:
        say("SSE/工具后续回复：未验证；可显式添加 --check-stream 发起一次额外回显检查。")


def verify_source(source):
    try:
        manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
        files = manifest["files"]
        if manifest["product"] != "sunmate-hermes" or manifest["version"] != VERSION or not isinstance(files, dict):
            raise ValueError()
        required = {"installer.py", "setup_hermes.sh", "install_to_hermes.sh", "README.md", "compatibility.json"}
        required.update(f"skills/{name}/{leaf}" for name in SKILLS for leaf in ("SKILL.md", "references/data-contract.md"))
        required.update(ARCHIVE_FILES)
        if set(files) != required:
            raise ValueError()
        for name, digest in files.items():
            path = source / name
            if path.is_symlink() or not path.is_file() or source.resolve() not in path.resolve().parents:
                raise ValueError()
            if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise ValueError()
        # Extra files must not be copied into Hermes under cover of the manifest.
        actual = {str(p.relative_to(source)).replace(os.sep, "/") for p in (source / "skills").rglob("*") if p.is_file()}
        if actual != {name for name in required if name.startswith("skills/")}:
            raise ValueError()
        if any(p.is_symlink() for p in (source / "skills").rglob("*")):
            raise ValueError()
    except (OSError, ValueError, KeyError, TypeError):
        raise InstallError("安装包不完整或 SHA-256 校验失败；请重新获取完整安装包。") from None
    return manifest


def tree_hashes(path):
    result = {}
    for item in path.rglob("*"):
        if item.is_symlink():
            raise InstallError("技能目标含符号链接，拒绝自动替换；请先人工核查。")
        relative = item.relative_to(path).as_posix()
        if item.is_file() and relative != ".sunmate-managed":
            result[relative] = hashlib.sha256(item.read_bytes()).hexdigest()
    return result


@contextmanager
def install_lock(home):
    lock = home / ".sunmate-install.lock"
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        raise InstallError("已有安装锁；请确认无安装进程后再处理 .sunmate-install.lock。") from None
    try:
        yield
    finally:
        lock.rmdir()


def install_skills(home, source, replace_modified=False):
    skills_dir = home / "skills"
    target = skills_dir / "sunmate"
    if skills_dir.is_symlink() or target.is_symlink():
        raise InstallError("skills 或 sunmate 目录为符号链接，拒绝自动写入。")
    if skills_dir.exists() and not skills_dir.is_dir():
        raise InstallError("skills 不是目录。")
    # Check even when the namespaced tree already matches: a later root-level
    # installation can otherwise silently shadow the managed skills.
    conflicts = [skills_dir / name for name in SKILLS if (skills_dir / name).exists() or (skills_dir / name).is_symlink()]
    if conflicts:
        raise InstallError("发现旧版/同名技能，未修改。请先将这些目录移到 skills 之外备份：" + ", ".join(str(p) for p in conflicts))
    expected = tree_hashes(source / "skills")
    if target.exists():
        marker_path = target / ".sunmate-managed"
        try:
            if marker_path.is_symlink():
                raise ValueError()
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            if marker.get("product") != "sunmate-hermes" or not isinstance(marker.get("files"), dict):
                raise ValueError()
        except (OSError, ValueError, TypeError):
            raise InstallError("已有 sunmate 目录不属于本安装器管理，未覆盖；请人工保留或迁移。") from None
        current = tree_hashes(target)
        if current == expected:
            say("五个 Skills 内容一致，跳过写入（幂等）。")
            return
        if current != marker["files"] and not replace_modified:
            raise InstallError("检测到用户修改或新增文件，已保留；确认后可用 --replace-modified 备份并升级。")
    skills_dir.mkdir(exist_ok=True)
    backup = None
    with tempfile.TemporaryDirectory(prefix=".sunmate-stage-", dir=home) as temporary:
        staged = Path(temporary) / "sunmate"
        shutil.copytree(source / "skills", staged)
        marker = {"product": "sunmate-hermes", "version": VERSION, "files": expected}
        marker_path = staged / ".sunmate-managed"
        marker_path.write_text(json.dumps(marker, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        marker_path.chmod(0o600)
        if target.exists():
            backups = home / "sunmate-backups"
            if backups.is_symlink():
                raise InstallError("备份目录是符号链接，拒绝写入。")
            backups.mkdir(mode=0o700, exist_ok=True)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            backup = backups / ("sunmate-" + stamp + "-" + uuid.uuid4().hex[:8])
            target.rename(backup)
        try:
            staged.rename(target)
        except OSError:
            if backup is not None:
                backup.rename(target)
            raise
    say(f"已安装五个 Skills：{target}")
    if backup:
        say(f"旧版本已备份（位于 skills 扫描范围外）：{backup}")


def verify_discovery(base, key):
    status, data = api_request(base, "/skills", key)
    if status == 404:
        say("当前 API 未提供 /v1/skills；文件已安装，技能加载尚未验证，请在 Hermes 中检查技能列表。")
        return
    if status != 200:
        raise InstallError(f"技能发现检查失败（HTTP {status}），文件已保留。")
    rows = data if isinstance(data, list) else data.get("skills", data.get("data", [])) if isinstance(data, dict) else []
    found = {row.get("name") for row in rows if isinstance(row, dict)}
    missing = set(SKILLS) - found
    if missing:
        raise InstallError("文件已安装，但 Hermes API 未发现以下技能：" + ", ".join(sorted(missing)) + "；请检查禁用设置或显式使用 --restart-native。")
    say("Hermes 原生 API 已发现全部五个 Skills。")


def parser():
    p = argparse.ArgumentParser(description="SunMate：安装五个 Skills 并验证已有 Hermes 原生 API，不修改 Hermes 核心配置。")
    p.add_argument("--hermes-home", help="已有 Hermes 配置目录；默认 HERMES_HOME / 标准目录")
    p.add_argument("--profile", "--hermes-profile", dest="profile", help="已有 profile 名称")
    p.add_argument("--base-url", help="实际原生 API 地址（含 /v1）；覆盖配置探测结果")
    p.add_argument("--app-url", help="手机访问的 HTTPS 地址；单独验证后才输出为可用端点")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--skills-only", action="store_true", help="只安装技能，明确不验证连接")
    mode.add_argument("--check", action="store_true", help="只检查连接，不安装文件、不重启")
    p.add_argument("--restart-native", action="store_true", help="通过 Hermes 官方命令重启目标 profile gateway")
    p.add_argument("--replace-modified", action="store_true", help="备份本安装器管理目录中的用户修改后再升级")
    p.add_argument("--check-stream", action="store_true", help="额外发一次随机文本SSE请求；验证流式结束，不自动调用业务工具")
    p.add_argument("--timeout", type=int, default=180, help="真实推理请求超时秒数，默认 180，上限 600")
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    if args.check and args.restart_native:
        raise InstallError("--check 不执行重启；请移除 --restart-native。")
    if args.skills_only and args.check_stream:
        raise InstallError("--skills-only 不执行 API 请求；请移除 --check-stream。")
    if not 1 <= args.timeout <= 600:
        raise InstallError("--timeout 应在 1–600 秒之间。")
    binary = shutil.which("hermes")
    if not binary:
        raise InstallError("未安装 Hermes 或 hermes 不在 PATH；未修改任何文件。")
    run_hermes(binary, ["--version"])
    home = select_home(args)
    if not args.check:
        verify_source(ROOT)
    settings = None
    base = app_url = None
    if not args.skills_only:
        settings = native_settings(home, binary)
        base, loopback = normalize_url(args.base_url or settings["url"])
        if args.app_url:
            app_url, app_loopback = normalize_url(args.app_url)
            if app_loopback:
                raise InstallError("手机端点不能是服务器回环地址；请提供手机实际可访问的 HTTPS 地址。")
    if args.check:
        model = check_api(base, settings["key"], args.timeout)
        if args.check_stream:
            check_stream(base, settings["key"], model, args.timeout)
        say("技能发现：本次 --check 只查连接；未验证技能加载，请在 Hermes 查看技能列表或执行标准安装检查。")
    else:
        with install_lock(home):
            # Preflight before writing skills, unless a restart was explicitly
            # requested to bring an already configured native service online.
            if settings and not args.restart_native:
                model = check_api(base, settings["key"], args.timeout)
                if args.check_stream:
                    check_stream(base, settings["key"], model, args.timeout)
            install_skills(home, ROOT, args.replace_modified)
            if args.restart_native:
                say("正在通过 Hermes 官方命令重启所选配置目录的 gateway…")
                run_hermes(binary, ["gateway", "restart"], home=home, timeout=60)
                if settings:
                    deadline = time.monotonic() + 30
                    while True:
                        try:
                            status, _ = api_request(base, "/models", settings["key"], timeout=2)
                        except InstallError:
                            status = 0
                        if status == 200:
                            break
                        if status in (401, 403):
                            raise InstallError("重启后的 API 鉴权失败。")
                        if time.monotonic() >= deadline:
                            raise InstallError("原生服务 30 秒内未就绪；请查看 Hermes gateway status。")
                        time.sleep(1)
                    model = check_api(base, settings["key"], args.timeout)
                    if args.check_stream:
                        check_stream(base, settings["key"], model, args.timeout)
    if args.skills_only:
        say("Skills 安装完成；API、模型推理、记忆写入及手机可达性均未验证。")
        report_app_capabilities()
        return 0
    if not args.check:
        verify_discovery(base, settings["key"])
    if app_url and app_url != base:
        say("正在单独检查手机访问地址…")
        app_model = check_api(app_url, settings["key"], args.timeout)
        if args.check_stream:
            check_stream(app_url, settings["key"], app_model, args.timeout)
    say("原生 API 鉴权及真实推理自检通过；不代表记忆写入、ASR 或手机网络已通过。")
    say(f"本次验证地址：{base}")
    say(f"模型标识：{model}")
    if model != "hermes-agent":
        say("本次仅验证上述模型；App默认请求hermes-agent，该标识能否使用仍需手机测试确认。")
    if app_url or not loopback:
        say(f"手机 App Hermes 地址：{app_url or base}")
        say("此地址已从服务器验证，仍需在手机上点击测试连接。")
    else:
        say("手机可访问端点尚未配置：127.0.0.1/localhost 指向手机自身，不能直接填入手机。")
        say("请配置 HTTPS 反代或安全隧道，再用 --app-url 验证真实手机访问地址。")
    say("Token：使用目标 profile 已有的 API_SERVER_KEY；请在本机安全查看并填入 App，勿粘贴到聊天或日志。")
    report_app_capabilities(args.check_stream)
    return 0


if __name__ == "__main__":
    if sys.version_info < (3, 9):
        raise SystemExit("错误：需要 Python 3.9+。")
    try:
        sys.exit(main())
    except (InstallError, OSError) as error:
        # OS error strings can contain user-controlled filenames, but not API
        # bodies, HTTP headers or config contents. All network errors are fixed.
        say(f"错误：{error}")
        sys.exit(1)
