"""Loopback HTTP entry; expose remotely only behind an authenticated TLS entry."""
import argparse
import hashlib
import hmac
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import secrets
import uuid
import os
import sqlite3
from .store import Archive, SCHEMA

MAX_BODY = 2 * 1024 * 1024
ROUTES = (('GET', '/sunmate/v1/capabilities'),
          ('POST', '/sunmate/v1/ingest'), ('POST', '/sunmate/v1/receipts'))


def load_config(root):
    path = Path(root) / "config.json"
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise ValueError("private_config_permissions_required")
    data = json.loads(path.read_text())
    if data.get('schema') != SCHEMA or not all(isinstance(data.get(k), str) and data[k] for k in ('serverId', 'libraryId', 'profile')):
        raise ValueError("invalid_config")
    return data


def initialize(root, profile):
    root = Path(root).absolute()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink() or any(root.iterdir()):
        raise ValueError("new_empty_directory_required")
    token = secrets.token_urlsafe(32)
    config = {'schema': SCHEMA, 'serverId': str(uuid.uuid4()), 'libraryId': str(uuid.uuid4()), 'profile': profile,
              'clients': {str(uuid.uuid4()): hashlib.sha256(token.encode()).hexdigest()}}
    config['maxDatabaseBytes'] = 512 * 1024 * 1024
    for name, value in [('config.json', json.dumps(config)), ('client-token.txt', token)]:
        with (root / name).open('x') as file:
            (root / name).chmod(0o600)
            file.write(value)
    Archive(root / 'records.sqlite')


def change_client(root, revoke=None):
    root = Path(root)
    config = load_config(root)
    if revoke is not None:
        if revoke not in config['clients']:
            raise ValueError('unknown_client')
        config['clients'].pop(revoke)
        result = None
    else:
        token = secrets.token_urlsafe(32)
        client = str(uuid.uuid4())
        config['clients'][client] = hashlib.sha256(token.encode()).hexdigest()
        result = root / ('client-' + client + '-token.txt')
        with result.open('x') as file:
            result.chmod(0o600)
            file.write(token)
    # Preserve previous authorization config before an explicit local admin change.
    backup = root / ('config-' + str(uuid.uuid4()) + '.backup.json')
    with backup.open('x') as file:
        backup.chmod(0o600)
        file.write((root / 'config.json').read_text())
    pending = root / ('config-' + str(uuid.uuid4()) + '.partial')
    with pending.open('x') as file:
        pending.chmod(0o600)
        file.write(json.dumps(config))
        file.flush(); os.fsync(file.fileno())
    pending.replace(root / 'config.json')
    return result


class ArchiveAPI:
    """The same authorization, validation and receipts for both HTTP hosts."""

    def __init__(self, root, profile=None):
        self.root = Path(root)
        self.profile = profile

    def authorize(self, headers):
        config = load_config(self.root)
        if self.profile is not None and config['profile'] != self.profile:
            raise ValueError('profile_mismatch')
        supplied = headers.get('Authorization', '')
        digest = hashlib.sha256(supplied[7:].encode()).hexdigest() if supplied.startswith('Bearer ') else ''
        client = next((key for key, value in config['clients'].items() if hmac.compare_digest(value, digest)), None)
        return config, client

    def handle(self, method, path, headers, body=b''):
        try:
            config, client = self.authorize(headers)  # Reload for immediate revocation.
            if not client:
                return 401, {'error': 'authentication_required'}
            if (method, path) not in ROUTES:
                return 404, {'error': 'unknown_route'}
            identity = {k: config[k] for k in ('serverId', 'libraryId', 'profile')}
            base = {'schema': SCHEMA, **identity, 'clientId': client}
            if method == 'GET':
                return 200, {**base, 'maxBatch': 50, 'rawAudio': False,
                    'tools': ['sunmate_search', 'sunmate_get', 'sunmate_stats', 'sunmate_sync_status']}
            if any(headers.get('X-Sunmate-' + key) != config[key] for key in ('serverId', 'libraryId')):
                return 409, {'error': 'identity_changed'}
            if not 1 <= len(body) <= MAX_BODY:
                return 400, {'error': 'invalid_request'}
            value = json.loads(body)
            if not isinstance(value, dict) or value.get('schema') != SCHEMA:
                raise ValueError()
            # Initialization is an explicit admin operation, never an HTTP side effect.
            if not (self.root / 'records.sqlite').is_file():
                return 503, {'error': 'archive_unavailable'}
            archive = Archive(self.root / 'records.sqlite')
            if path == '/sunmate/v1/ingest':
                if archive.path.stat().st_size >= config.get('maxDatabaseBytes', 512 * 1024 * 1024):
                    return 507, {'error': 'archive_capacity_reached'}
                return 200, {**base, 'receipts': archive.ingest(client, value['records'])}
            return 200, {**base, 'receipts': archive.receipts(client, value['refs'])}
        except (ValueError, KeyError, TypeError, UnicodeError):
            return 400, {'error': 'invalid_request'}
        except sqlite3.OperationalError as error:
            return 507 if 'full' in str(error).lower() else 503, {'error': 'archive_unavailable'}
        except Exception:
            return 503, {'error': 'archive_unavailable'}


def make_server(root, host='127.0.0.1', port=0):
    api = ArchiveAPI(root)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.0'
        def log_message(self, *args):
            pass  # Never log URLs, authorization, or content.

        def reply(self, status, value):
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def dispatch(self, post=False):
            try:
                self.connection.settimeout(10)
                _, client = api.authorize(self.headers)
                if not client:
                    return self.reply(401, {'error': 'authentication_required'})
                body = b''
                if post:
                    length = int(self.headers.get('Content-Length', '-1'))
                    if not 1 <= length <= MAX_BODY or self.headers.get('Transfer-Encoding'):
                        return self.reply(400, {'error': 'invalid_request'})
                    body = self.rfile.read(length)
                return self.reply(*api.handle('POST' if post else 'GET', self.path, self.headers, body))
            except (ValueError, KeyError, TypeError):
                return self.reply(400, {'error': 'invalid_request'})
            except sqlite3.OperationalError as error:
                return self.reply(507 if 'full' in str(error).lower() else 503, {'error': 'archive_unavailable'})
            except Exception:
                return self.reply(503, {'error': 'archive_unavailable'})

        def do_GET(self):
            self.dispatch()

        def do_POST(self):
            self.dispatch(True)

    return ThreadingHTTPServer((host, port), Handler)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--initialize', action='store_true')
    parser.add_argument('--profile', default='default')
    parser.add_argument('--port', type=int, default=8765)
    changes = parser.add_mutually_exclusive_group()
    changes.add_argument('--add-client', action='store_true')
    changes.add_argument('--revoke-client')
    args = parser.parse_args()
    if args.initialize and (args.add_client or args.revoke_client):
        parser.error('initialize and client changes are separate operations')
    if args.add_client or args.revoke_client:
        change_client(args.root, args.revoke_client)
    elif args.initialize:
        initialize(args.root, args.profile)
    else:
        make_server(args.root, port=args.port).serve_forever()


if __name__ == '__main__':
    main()
