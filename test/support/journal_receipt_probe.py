"""Exercise bounded HTTP receipt parsing without making network requests."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

source = Path(__file__).resolve().parents[2] / "priv/nonce_journal/journal_io.py"
spec = importlib.util.spec_from_file_location("journal_io", source)
journal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(journal)


class ReceiptTests(unittest.TestCase):
    def dispatch(self, body, status=201):
        reads = []

        class Response:
            def read(self, limit):
                reads.append(limit)
                return body[:limit]

        response = Response()
        response.status = status

        class Connection:
            def __init__(self, *args, **kwargs):
                pass

            def connect(self):
                pass

            def request(self, *args):
                pass

            def getresponse(self):
                return response

            def close(self):
                pass

        original = journal.http.client.HTTPConnection
        journal.http.client.HTTPConnection = Connection
        try:
            with tempfile.TemporaryDirectory() as directory:
                name = "sha256:" + "a" * 64 + ".json"
                entry = {"candidate": {"target": {"group": "test", "version": "v1", "kind": "Record", "name": None}, "spec": {}}, "envelope": {}}
                (Path(directory) / name).write_text(json.dumps(entry))
                result = journal.dispatch(directory, {"name": name, "url": "http://localhost:1", "timeout": 100})
                self.assertEqual(reads, [journal.MAX_RECEIPT + 1])
                return result
        finally:
            journal.http.client.HTTPConnection = original

    def test_locator_is_only_a_hint(self):
        ref = "event:sha256:" + "b" * 64
        self.assertEqual(self.dispatch(json.dumps({"eventRef": ref}).encode()),
                         {"status": "acknowledged", "event_ref_hint": ref})

    def test_bad_receipt_drops_hint_but_preserves_canonical_lookup(self):
        for body in [b" " * (journal.MAX_RECEIPT + 1), b"invalid", b"\xff"]:
            self.assertEqual(self.dispatch(body), {"status": "acknowledged"})

    def test_invalid_locator_is_not_returned(self):
        for value in [None, 4, "event:wrong", "event:sha256:" + "A" * 64]:
            self.assertEqual(self.dispatch(json.dumps({"eventRef": value}).encode()),
                             {"status": "acknowledged"})

    def test_non_grant_response_cannot_become_acknowledged(self):
        self.assertEqual(self.dispatch(b"{}", status=503), {"status": "uncertain"})


if __name__ == "__main__":
    unittest.main()
