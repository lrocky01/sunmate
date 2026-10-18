#!/usr/bin/env python3
"""Loopback-only, user-operated normal account probe. No raw credentials/log files.

App SMS path/body/channel are observed APK contracts. Login path is observed;
its body is a candidate assembled from the adjacent verification API and website
login fields, NOT a recovered/observed Android login transaction.
"""

import argparse
import base64
import hmac
import html
import json
import re
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

SERVICE = "https://openclaw-service.yoooclaw.com"
SMS = "/api/account/auth/open/sendLoginSms"
LOGIN = "/api/account/auth/login/open/loginOrRegister"
PROFILE = "/api/account/user/profile/info"
DEVICES = "/api/device/toc/homePage/pub/index"
SUCCESS = {"200", "000000", "0"}
REASONS = {
    "Jwt is missing": "missing_credential",
    "Jwt is expired": "expired",
    "Jwt issuer is not configured": "issuer_not_configured",
    "Jwt audience is not allowed": "audience_rejected",
    "Jwt verification fails": "signature_rejected",
    "Jwt is not yet valid": "not_yet_valid",
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request(method, path, data=None, token=None, user_id=None):
    if (method, path) not in {("POST", SMS), ("POST", LOGIN),
                             ("GET", PROFILE), ("POST", DEVICES)}:
        raise ValueError("Unsupported endpoint")
    headers = {"Content-Type": "application/json", "app_key": "yoooclaw"}
    if token is not None:
        headers["Authorization"] = "Bearer " + token
        headers["UserId"] = user_id
        headers["user_id"] = user_id
    req = urllib.request.Request(SERVICE + path, method=method, headers=headers,
                                 data=None if data is None else json.dumps(data).encode())
    try:
        response = urllib.request.build_opener(NoRedirect).open(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    except (OSError, ValueError):
        return {"http": None, "reason": "network_error"}, None
    with response:
        raw = response.read(2 * 1024 * 1024 + 1)
        result = {"http": response.status}
        if len(raw) > 2 * 1024 * 1024:
            return {**result, "reason": "response_too_large"}, None
        challenge = response.headers.get("WWW-Authenticate", "")
        if re.match(r"Bearer\b", challenge, re.I):
            result["authentication"] = "Bearer"
        text = raw.decode("utf-8", "replace")
        if text.strip() in REASONS:
            result["reason"] = REASONS[text.strip()]
        try:
            body = json.loads(text)
        except ValueError:
            return result, None
        if not isinstance(body, dict):
            return {**result, "reason": "unexpected_shape"}, None
        code = str(body.get("code", ""))
        if re.fullmatch(r"[0-9]{1,6}", code):
            result["code"] = code
        # Neither vendor msg nor response data may be copied into public output.
        return result, body


def accepted(summary):
    return summary.get("http") == 200 and summary.get("code") in SUCCESS


def normalize_session(user):
    if not isinstance(user, dict):
        raise ValueError("Missing session")
    token, user_id = user.get("jwtToken"), str(user.get("id", ""))
    if not isinstance(token, str):
        raise ValueError("Missing token")
    token = re.sub(r"^Bearer\s+", "", token.strip(), flags=re.I)
    if not re.fullmatch(r"[A-Za-z0-9._~+/-]+=*", token) or len(token) > 8192:
        raise ValueError("Invalid token format")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", user_id):
        raise ValueError("Invalid user id")
    return token, user_id


def token_metadata(token):
    result = {"format": "opaque_or_unsupported"}
    parts = token.split(".")
    if len(parts) != 3:
        return result
    try:
        def decode(part):
            return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
        head, claims = decode(parts[0]), decode(parts[1])
        if not isinstance(head, dict) or not isinstance(claims, dict):
            return result
        result = {"format": "jwt_unverified"}  # Parsing never grants access.
        alg = head.get("alg")
        result["algorithm"] = alg if alg in {"HS256", "HS384", "HS512", "RS256",
            "RS384", "RS512", "ES256", "ES384", "ES512", "EdDSA", "none"} else "other"
        issuer = claims.get("iss")
        host = urllib.parse.urlsplit(issuer).hostname if isinstance(issuer, str) else None
        result["issuer_host"] = host if host in {
            "yoooclaw.com", "www.yoooclaw.com", "openclaw-service.yoooclaw.com",
            "auth.yoooclaw.com", "account.yoooclaw.com", "portal.yoooclaw.com"
        } else "unreported_or_other"
        exp = claims.get("exp")
        result["expired"] = exp < time.time() if isinstance(exp, (int, float)) else None
        result["audience_present"] = "aud" in claims
        channel = str(claims.get("channel", ""))
        result["channel"] = channel if channel in {"3", "6"} else "unreported_or_other"
        return result
    except (ValueError, TypeError, UnicodeError):
        return result


def binding_metadata(record):
    """Classify only known fields; never export field values or arbitrary keys."""
    info = record.get("extInfo")
    if "extInfo" not in record:
        return {"ext_info": "missing", "shared_secret": "unavailable"}
    if info is None:
        return {"ext_info": "null", "shared_secret": "unavailable"}
    kind = "object"
    if isinstance(info, str):
        kind = "string"
        if len(info) <= 65536:
            try:
                parsed = json.loads(info)
                if isinstance(parsed, dict):
                    info, kind = parsed, "json_string_object"
            except ValueError:
                pass
    if not isinstance(info, dict):
        return {"ext_info": kind if isinstance(info, str) else "other",
                "shared_secret": "unavailable"}
    value = info.get("sharedSecret")
    status = "missing" if "sharedSecret" not in info else "null"
    if value is not None:
        status = "wrong_type"
        if isinstance(value, str):
            status = "empty" if not value.strip() else "invalid_base64"
            if value.strip() and len(value) <= 8192:
                try:
                    key = base64.b64decode(value.strip(), validate=True)
                    status = ("not_32_bytes" if len(key) != 32 else
                              "valid_32_bytes" if any(key) else "all_zero")
                except ValueError:
                    pass
    return {"ext_info": kind, "shared_secret": status}


def probe(phone, code, target_sn, transport=request):
    if not re.fullmatch(r"1[3-9][0-9]{9}", phone) or not re.fullmatch(r"[0-9]{4}", code):
        return {"result": "invalid_input"}
    summary, body = transport("POST", LOGIN, {
        "phone": phone, "smsCode": code, "channel": "3", "deviceId": "deviceId"})
    report = {"source": "official_app_endpoint_candidate_body", "login": summary}
    if not accepted(summary):
        return report
    try:
        token, user_id = normalize_session(body.get("data"))
    except (ValueError, AttributeError):
        return {**report, "result": "session_shape_unsupported"}
    report["token_metadata"] = token_metadata(token)
    # Exactly two read-only requests with this legitimately issued session.
    profile, _ = transport("GET", PROFILE, token=token, user_id=user_id)
    devices, body = transport("POST", DEVICES, token=token, user_id=user_id)
    report["profile"], report["devices"] = profile, devices
    if accepted(devices) and isinstance(body, dict):
        data = body.get("data")
        records = data.get("deviceList") if isinstance(data, dict) else None
        if isinstance(records, list) and len(records) <= 1000:
            report["device_count"] = len(records)
            matches = [r for r in records if isinstance(r, dict) and
                       str(r.get("externalDeviceId", "")).upper() == target_sn.upper()]
            report["target_match_count"] = len(matches)
            if len(matches) == 1:
                metadata = binding_metadata(matches[0])
                report["target_binding_shape"] = metadata
                report["target_has_valid_shared_secret"] = (
                    metadata == {"ext_info": "object", "shared_secret": "valid_32_bytes"})
    return report


PAGE = """<!doctype html><meta charset=utf-8><title>SunMate 本机账号诊断</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>body{max-width:640px;margin:40px auto;padding:16px;font:16px system-ui;line-height:1.7}
input,button{font:inherit;padding:10px;margin:8px 0;box-sizing:border-box;width:100%}
pre{white-space:pre-wrap;word-break:break-word;background:#f1f4f6;padding:16px}</style>
<h1>官方 App 账号接口诊断</h1>
<p>仅在这台 Mac 本机提供页面。手机号、验证码、会话及设备资料仅在本次进程内存中使用。
请求仅发往官方 openclaw-service.yoooclaw.com；不处理录音或私有 ASR/Hermes。</p>
<p>APK 已确认短信入口和渠道 3；登录请求字段由相邻验证码接口和官网结构组合，
尚未捕获完整 App 登录请求。本次验证用于确认其是否被真实服务接受，不会自动尝试其它渠道。</p>
<form method=post action=/probe autocomplete=off>
<input type=hidden name=nonce value="{nonce}">
<label>自己的官方账号手机号<input name=phone inputmode=tel maxlength=11 value="{phone}" required></label>
<button name=action value=sms formnovalidate>发送 App 渠道验证码</button>
<label>4 位验证码<input name=code type=password inputmode=numeric maxlength=4></label>
<button name=action value=login>登录并只读验证设备列表</button></form>
<p>{status}</p><pre>{report}</pre>
<p>不要把验证码、Token 或整份官方日志发送到聊天。诊断结果只保留状态和白名单元数据。</p>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def page(self, status="", report=None, phone=""):
        output = PAGE.replace("{nonce}", self.server.nonce).replace(
            "{phone}", html.escape(phone, quote=True)).replace(
            "{status}", html.escape(status)).replace("{report}", html.escape(
                json.dumps(report or self.server.report, ensure_ascii=False, indent=2)))
        self.send_response(200)
        for key, value in {"Content-Type": "text/html; charset=utf-8",
            # A no-referrer policy makes native form POST Origin become null.
            # Preserve same-origin POSTs while withholding cross-origin referrers.
            "Cache-Control": "no-store", "Referrer-Policy": "same-origin",
            "X-Content-Type-Options": "nosniff", "Content-Security-Policy":
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"}.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(output.encode())

    def valid_host(self):
        return self.headers.get("Host") == self.server.authority

    def reject_form(self, reason):
        # Only fixed reason codes; never record headers, fields or credentials.
        self.server.report = {"result": "local_form_rejected", "reason": reason}
        self.send_error(403, "Local form rejected; reload the diagnostic home page")

    def do_GET(self):
        if not self.valid_host() or self.path not in {"/", "/status"}:
            self.send_error(404)
            return
        if self.path == "/status":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(json.dumps(self.server.report).encode())
            return
        self.page()

    def do_POST(self):
        if not self.valid_host() or self.path != "/probe":
            self.reject_form("wrong_host_or_path")
            return
        origin = self.headers.get("Origin")
        if origin != self.server.origin:
            self.reject_form("origin_null" if origin == "null" else
                             "origin_missing" if origin is None else "origin_mismatch")
            return
        length = self.headers.get("Content-Length", "")
        if not length.isdigit() or not 0 < int(length) <= 4096:
            self.send_error(400)
            return
        values = urllib.parse.parse_qs(self.rfile.read(int(length)).decode("utf-8", "replace"))
        if any(len(v) != 1 for v in values.values()) or not hmac.compare_digest(
                values.get("nonce", [""])[0], self.server.nonce):
            self.reject_form("invalid_form_token_or_duplicate_fields")
            return
        phone = values.get("phone", [""])[0].strip()
        if not re.fullmatch(r"1[3-9][0-9]{9}", phone):
            self.page("请输入自己的有效手机号")
            return
        try:
            if values.get("action") == ["sms"]:
                if time.monotonic() - self.server.last_sms < 60:
                    self.page("请等待 60 秒后再发送")
                    return
                self.server.last_sms = time.monotonic()
                summary, _ = request("POST", SMS, {"phone": phone, "channel": "3", "deviceId": "deviceId"})
                self.server.report = {"sms": summary}
            elif values.get("action") == ["login"]:
                self.server.report = probe(phone, values.get("code", [""])[0].strip(), self.server.target_sn)
            else:
                self.send_error(400)
                return
            self.page("操作已结束，请查看脱敏结果", phone=phone)
        except Exception:
            self.page("诊断未完成；未输出异常正文或凭据")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-sn", required=True)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z]{2}[0-9]{14}", args.target_sn):
        raise SystemExit("Invalid recorder SN")
    if not 0 <= args.port <= 65535:
        parser.error("port must be between 0 and 65535")
    server = HTTPServer(("127.0.0.1", args.port), Handler)
    server.nonce = secrets.token_urlsafe(32)
    server.authority = "127.0.0.1:" + str(server.server_port)
    server.origin = "http://" + server.authority
    server.last_sms = float("-inf")
    server.report = {"result": "awaiting_user"}
    server.target_sn = args.target_sn
    print(server.origin + "/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        server.report = {}


if __name__ == "__main__":
    main()
