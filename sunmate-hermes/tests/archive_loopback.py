"""Synthetic test fixture for Dart -> real Python HTTP/SQLite interoperability."""
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from archive_runtime.service import initialize, make_server

root = Path(sys.argv[1]) / 'sunmate-archive'
initialize(root, 'default')
server = make_server(root)
print(json.dumps({'port': server.server_port, 'token': (root / 'client-token.txt').read_text()}), flush=True)
server.serve_forever()
