"""Offline privacy and normal authentication contract checks; no real SMS/API calls."""
import base64
import importlib.util
import json
from pathlib import Path
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("probe", Path(__file__).with_name("official_account_probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
SN = "AB00000000000001"


class ProbeTests(unittest.TestCase):
    def test_issued_session_reads_only_profile_and_devices_and_never_exports_credentials(self):
        calls = []
        def transport(method, path, data=None, **auth):
            calls.append((method, path, data, auth))
            summary = {"http": 200, "code": "000000"}
            if path == probe.LOGIN:
                return summary, {"data": {"jwtToken": "Bearer test-only-session", "id": "123"}}
            if path == probe.PROFILE:
                return summary, {"data": {"phoneNumber": "13800000000", "nickName": "private-name"}}
            return summary, {"data": {"deviceList": [{"externalDeviceId": SN,
                "extInfo": {"sharedSecret": base64.b64encode(bytes(range(1, 33))).decode()}}]}}
        result = probe.probe("13800000000", "1234", SN, transport)
        self.assertTrue(result["target_has_valid_shared_secret"])
        self.assertEqual([c[:2] for c in calls], [("POST", probe.LOGIN), ("GET", probe.PROFILE), ("POST", probe.DEVICES)])
        self.assertEqual(calls[0][2], {"phone": "13800000000", "smsCode": "1234", "channel": "3", "deviceId": "deviceId"})
        self.assertEqual(calls[1][3], {"token": "test-only-session", "user_id": "123"})
        text = json.dumps(result)
        for secret in ["test-only-session", "13800000000", "1234", "private-name", SN,
                       base64.b64encode(bytes(range(1, 33))).decode()]:
            self.assertNotIn(secret, text)

    def test_failed_login_has_no_credential_retry_or_device_access(self):
        calls = []
        def transport(*args, **kwargs):
            calls.append(args)
            return {"http": 200, "code": "400"}, {"msg": "private-response"}
        result = probe.probe("13800000000", "1234", SN, transport)
        self.assertEqual(len(calls), 1)
        self.assertNotIn("private-response", str(result))
        self.assertNotIn("devices", result)
        self.assertEqual(probe.probe("bad-phone", "1234", SN, transport), {"result": "invalid_input"})
        self.assertEqual(len(calls), 1)

    def test_binding_shape_reports_missing_or_encoded_material_without_values(self):
        secret = base64.b64encode(bytes(range(1, 33))).decode()
        cases = [
            ({}, "missing", "unavailable"),
            ({"extInfo": None}, "null", "unavailable"),
            ({"extInfo": {}}, "object", "missing"),
            ({"extInfo": {"sharedSecret": None}}, "object", "null"),
            ({"extInfo": {"sharedSecret": ""}}, "object", "empty"),
            ({"extInfo": {"sharedSecret": "private-value"}}, "object", "invalid_base64"),
            ({"extInfo": {"sharedSecret": "YWJj"}}, "object", "not_32_bytes"),
            ({"extInfo": {"sharedSecret": base64.b64encode(bytes(32)).decode()}}, "object", "all_zero"),
            ({"extInfo": {"sharedSecret": secret}}, "object", "valid_32_bytes"),
            ({"extInfo": json.dumps({"sharedSecret": secret})}, "json_string_object", "valid_32_bytes"),
        ]
        for record, kind, status in cases:
            with self.subTest(kind=kind, status=status):
                record["private-field"] = "private-account-data"
                result = probe.binding_metadata(record)
                self.assertEqual(result, {"ext_info": kind, "shared_secret": status})
                for value in [secret, "private-value", "private-account-data", "YWJj"]:
                    self.assertNotIn(value, json.dumps(result))
    def test_duplicate_target_cannot_report_a_unique_recoverable_secret(self):
        def transport(method, path, **kwargs):
            return {"http": 200, "code": "200"}, {"data": {"deviceList": [{"externalDeviceId": SN}] * 2}}
        calls = 0
        def session_then_records(method, path, data=None, **kwargs):
            nonlocal calls
            calls += 1
            if path == probe.LOGIN:
                return {"http": 200, "code": "200"}, {"data": {"jwtToken": "test-only-session", "id": "123"}}
            return transport(method, path)
        result = probe.probe("13800000000", "1234", SN, session_then_records)
        self.assertEqual(result["target_match_count"], 2)
        self.assertNotIn("target_has_valid_shared_secret", result)
        self.assertEqual(calls, 3)

    def test_jwt_metadata_is_unverified_and_whitelisted(self):
        def part(value):
            return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
        token = part({"alg": "RS256"}) + "." + part({"iss": "https://private-value.yoooclaw.com",
            "sub": "13800000000", "aud": ["private-audience"], "channel": 3, "exp": 1}) + ".test"
        result = probe.token_metadata(token)
        self.assertEqual(result["format"], "jwt_unverified")
        self.assertEqual(result["channel"], "3")
        self.assertTrue(result["expired"])
        for value in ["private-value", "private-audience", "13800000000", token]:
            self.assertNotIn(value, json.dumps(result))
        self.assertEqual(probe.token_metadata("opaque"), {"format": "opaque_or_unsupported"})

    def test_no_redirect_or_unrecognized_endpoint_can_forward_credentials(self):
        self.assertIsNone(probe.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))
        with self.assertRaises(ValueError):
            probe.request("POST", "/unknown", token="test-only-session", user_id="123")
        with self.assertRaises(ValueError):
            probe.normalize_session({"jwtToken": "bad\r\nheader", "id": "123"})

    def test_loopback_form_rejects_cross_origin_nonce_replay_and_sms_bursts(self):
        server = probe.HTTPServer(("127.0.0.1", 0), probe.Handler)
        server.authority = "127.0.0.1:" + str(server.server_port)
        server.origin = "http://" + server.authority
        server.nonce, server.report, server.last_sms, server.target_sn = "test-only-nonce", {}, float("-inf"), SN
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            data = {"action": "sms", "nonce": "test-only-nonce", "phone": "13800000000"}
            def post(origin, nonce=None):
                body = dict(data)
                if nonce is not None:
                    body["nonce"] = nonce
                req = urllib.request.Request(server.origin + "/probe", method="POST",
                    data=urllib.parse.urlencode(body).encode(),
                    headers={} if origin is None else {"Origin": origin})
                return urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=3)
            with patch.object(probe, "request", return_value=({"http": 200, "code": "000000"}, None)) as request:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(server.origin + "/", timeout=3) as response:
                    self.assertEqual(response.headers["Referrer-Policy"], "same-origin")
                    self.assertIn("form-action 'self'", response.headers["Content-Security-Policy"])
                for origin, nonce, reason in [
                        ("http://other.invalid", None, "origin_mismatch"),
                        ("null", None, "origin_null"),
                        (None, None, "origin_missing"),
                        (server.origin, "wrong", "invalid_form_token_or_duplicate_fields")]:
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        post(origin, nonce)
                    self.assertEqual(error.exception.code, 403)
                    self.assertEqual(server.report, {"result": "local_form_rejected", "reason": reason})
                self.assertEqual(request.call_count, 0)
                with post(server.origin) as response:
                    self.assertEqual(response.status, 200)
                with post(server.origin) as response:
                    response.read()
                self.assertEqual(request.call_count, 1)
                with urllib.request.urlopen(server.origin + "/status", timeout=3) as response:
                    result = response.read().decode()
                self.assertNotIn("13800000000", result)
                self.assertNotIn("test-only-nonce", result)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
