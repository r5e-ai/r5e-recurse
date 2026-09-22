import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('run_probe', Path(__file__).resolve().parents[2] / 'priv/live/run_probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class CredentialEvidenceTest(unittest.TestCase):
    def test_rejects_known_secret_even_under_innocent_key(self):
        secret = 'a-private-value-with-no-token-prefix'
        with self.assertRaises(RuntimeError):
            probe.safe_evidence({'model': secret}, [secret])

    def test_rejects_unknown_bearer_or_token_shaped_value(self):
        for value in ['Bearer abcdefghi', 'sk-ant-' + 'a' * 24, 'eyJ' + 'a' * 24 + '.abc.def']:
            with self.assertRaises(RuntimeError):
                probe.safe_evidence({'result': value}, [])

    def test_canonical_hashes_and_refs_are_not_credentials(self):
        encoded = probe.safe_evidence({'call': 'event:sha256:' + 'a' * 64, 'refresh': 'unverified'}, [])
        self.assertIn('event:sha256:', encoded)

    def test_only_generated_collection_identity_can_enter_rpc(self):
        with self.assertRaises(ValueError):
            probe.collect('unused', 'codex', '#{System.cmd("bad", [])}', Path('/unused'))


if __name__ == '__main__':
    unittest.main()
