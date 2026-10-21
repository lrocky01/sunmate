"""Versioned SQLite archive. A receipt means the transaction committed."""
import hashlib
import json
import sqlite3
from contextlib import contextmanager, closing
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "sunmate.archive.v1"
KINDS = {"notification", "session", "transcript", "summary", "note"}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def fingerprint(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def timestamp(value):
    if not isinstance(value, str) or len(value) > 40:
        raise ValueError("invalid_time")
    date = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if date.tzinfo is None:
        raise ValueError("timezone_required")
    return date.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class Archive:
    def __init__(self, path, readonly=False):
        self.path = Path(path).absolute()
        self.readonly = readonly
        if self.path.is_symlink() or self.path.parent.is_symlink():
            raise ValueError("unsafe_archive_path")
        if not readonly:
            self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with self.connect() as db:
                db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS versions (
                    client TEXT NOT NULL, id TEXT NOT NULL, sha TEXT NOT NULL,
                    kind TEXT NOT NULL, time TEXT NOT NULL, body TEXT NOT NULL,
                    PRIMARY KEY(client,id,sha));
                CREATE TABLE IF NOT EXISTS heads (
                    client TEXT NOT NULL, id TEXT NOT NULL, sha TEXT NOT NULL,
                    revision INTEGER NOT NULL, visible INTEGER NOT NULL,
                    PRIMARY KEY(client,id));
                CREATE TABLE IF NOT EXISTS receipts (
                    client TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL,
                    sha TEXT NOT NULL, status TEXT NOT NULL, received TEXT NOT NULL,
                    PRIMARY KEY(client,id,revision));
                """)
            self.path.chmod(0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path.as_uri() + ("?mode=ro" if self.readonly else "?mode=rwc"), uri=True, timeout=5)
        db.row_factory = sqlite3.Row
        if self.readonly:
            db.execute("PRAGMA query_only=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    @staticmethod
    def validate(record):
        if not isinstance(record, dict) or set(record) != {"id", "revision", "sha", "kind", "timestamp", "payload", "visible"}:
            raise ValueError("invalid_record")
        if not isinstance(record["id"], str) or not 1 <= len(record["id"]) <= 1100:
            raise ValueError("invalid_id")
        if type(record["revision"]) is not int or not 1 <= record["revision"] <= 2**53 - 1:
            raise ValueError("invalid_revision")
        if record["kind"] not in KINDS or type(record["visible"]) is not bool or not isinstance(record["payload"], dict):
            raise ValueError("invalid_fields")
        timestamp(record["timestamp"])
        body = {key: record[key] for key in ("id", "kind", "timestamp", "payload", "visible")}
        if len(canonical(body).encode()) > 1024 * 1024 or fingerprint(body) != record["sha"]:
            raise ValueError("invalid_fingerprint")
        def safe(value):
            if isinstance(value, float):
                raise ValueError("integer_time_required")
            if isinstance(value, dict):
                for item in value.values(): safe(item)
            elif isinstance(value, list):
                for item in value: safe(item)
        safe(body)
        return body

    def ingest(self, client, records):
        if not isinstance(records, list) or not 1 <= len(records) <= 50:
            raise ValueError("invalid_batch")
        results = []
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            for record in records:
                receipt = {key: record.get(key) for key in ("id", "revision", "sha")} if isinstance(record, dict) else {}
                try:
                    body = self.validate(record)
                except (ValueError, TypeError, OverflowError):
                    results.append({**receipt, "status": "invalid"})
                    continue
                old = db.execute("SELECT * FROM receipts WHERE client=? AND id=? AND revision=?", (client, record['id'], record['revision'])).fetchone()
                head = db.execute("SELECT * FROM heads WHERE client=? AND id=?", (client, record['id'])).fetchone()
                status = "accepted"
                if old:
                    status = "already_present" if old['sha'] == record['sha'] else "conflict"
                elif head and record['revision'] <= head['revision']:
                    status = "conflict"
                else:
                    db.execute("INSERT OR IGNORE INTO versions VALUES (?,?,?,?,?,?)", (client, record['id'], record['sha'], record['kind'], timestamp(record['timestamp']), canonical(body)))
                    db.execute("INSERT OR REPLACE INTO heads VALUES (?,?,?,?,?)", (client, record['id'], record['sha'], record['revision'], int(record['visible'])))
                    db.execute("INSERT INTO receipts VALUES (?,?,?,?,?,?)", (client, record['id'], record['revision'], record['sha'], status, datetime.now(timezone.utc).isoformat()))
                results.append({**receipt, "status": status})
        return results

    def receipts(self, client, refs):
        if not isinstance(refs, list) or len(refs) > 50:
            raise ValueError("invalid_refs")
        with self.connect() as db:
            return [dict(row) if row else {**ref, "status": "missing"} for ref in refs for row in [db.execute(
                "SELECT id,revision,sha,status FROM receipts WHERE client=? AND id=? AND revision=? AND sha=?",
                (client, ref['id'], ref['revision'], ref['sha'])).fetchone()]]

    def search(self, *, kind=None, keyword="", start=None, end=None, scope=None, app=None, purpose=None, offset=0, limit=20):
        if kind is not None and kind not in KINDS or not isinstance(keyword, str) or len(keyword) > 256:
            raise ValueError("invalid_query")
        if type(offset) is not int or offset < 0 or offset > 100000 or type(limit) is not int or not 1 <= limit <= 50:
            raise ValueError("invalid_page")
        clauses, args = ["h.visible=1"], []
        if kind:
            clauses.append("v.kind=?"); args.append(kind)
        for value, operator in ((start, ">="), (end, "<")):
            if value is not None:
                clauses.append("v.time" + operator + "?"); args.append(timestamp(value))
        # instr is literal, works for Chinese and cannot turn '%' into a wildcard.
        if keyword:
            clauses.append("instr(v.body,?)>0"); args.append(keyword)
        if scope is not None:
            clauses.append("json_extract(v.body,'$.payload.scope')=?"); args.append(scope)
        if app is not None:
            clauses.append("json_extract(v.body,'$.payload.appIdentifier')=?"); args.append(app)
        if purpose is not None:
            if purpose not in ('meeting', 'lifelog', 'notification'):
                raise ValueError('invalid_purpose')
            clauses.append("json_extract(v.body,'$.payload.purpose')=?"); args.append(purpose)
        with self.connect() as db:
            rows = db.execute("SELECT v.*,h.revision FROM heads h JOIN versions v USING(client,id,sha) WHERE " + " AND ".join(clauses) + " ORDER BY v.time,v.id LIMIT ? OFFSET ?", (*args, limit + 1, offset)).fetchall()
        records = []
        for row in rows[:limit]:
            value = self.output(row)
            payload = value['payload']
            value['payload'] = {key: payload[key] for key in ('scope', 'purpose', 'complete', 'partComplete', 'partial', 'timeConfidence', 'offsetMs', 'durationMs', 'sourceApp', 'appIdentifier', 'archivedParts', 'transcribedParts', 'recordingStopped', 'sourceVersionsKnown', 'sourceState', 'coverage') if key in payload}
            value['preview'] = payload.get('text', '')[:200]
            value['previewOnly'] = True
            records.append(value)
        return {"records": records, "nextOffset": offset + limit if len(rows) > limit else None, "coverage": "仅已归档且当前允许检索的资料；不代表手机全量。"}

    @staticmethod
    def output(row):
        return {**json.loads(row['body']), "clientId": row['client'], "sha": row['sha'], "revision": row['revision']}

    def get(self, client, id, sha):
        # A historical reference must still belong to a currently visible record.
        with self.connect() as db:
            row = db.execute("SELECT v.*,(SELECT max(revision) FROM receipts r WHERE r.client=v.client AND r.id=v.id AND r.sha=v.sha) revision FROM versions v JOIN heads h ON h.client=v.client AND h.id=v.id WHERE v.client=? AND v.id=? AND v.sha=? AND h.visible=1", (client, id, sha)).fetchone()
        return self.output(row) if row else None

    def stats(self):
        with self.connect() as db:
            counts = {row['kind']: row['n'] for row in db.execute("SELECT kind,count(*) n FROM heads JOIN versions USING(client,id,sha) WHERE visible=1 GROUP BY kind")}
            last = db.execute("SELECT max(received) FROM receipts").fetchone()[0]
        return {"counts": counts, "lastReceived": last, "coverage": "服务器已提交资料；手机未同步/未转写内容不可见。"}

    def backup(self, destination):
        target = Path(destination)
        if target.exists():
            raise ValueError("backup_exists")
        with self.connect() as source, closing(sqlite3.connect(str(target))) as out:
            source.backup(out)
            out.commit()
            out.execute("PRAGMA journal_mode=DELETE")
        target.chmod(0o600)
