"""Exercise framing failures without starting Vulkan or loading the runtime."""
import json
import struct
import subprocess
import sys
import unittest

WORKER = sys.argv.pop(1)


def frame(message):
    payload = json.dumps(message).encode()
    return struct.pack("<I", len(payload)) + payload


class ProtocolTests(unittest.TestCase):
    def run_worker(self, payload):
        return subprocess.run([WORKER], input=payload, capture_output=True, timeout=5)

    def test_session_and_recoverable_error(self):
        messages = [{"id": 1, "version": 1, "op": "hello"},
                    {"id": 2, "version": 1, "op": "unknown"},
                    {"id": 3, "version": 1, "op": "shutdown"}]
        result = self.run_worker(b"".join(map(frame, messages)))
        self.assertEqual(result.returncode, 0, result.stderr)
        stream = result.stdout
        replies = []
        while stream:
            size, = struct.unpack("<I", stream[:4])
            replies.append(json.loads(stream[4:4 + size]))
            stream = stream[4 + size:]
        self.assertEqual([r["id"] for r in replies], [1, 2, 3])
        self.assertEqual([r["ok"] for r in replies], [True, False, True])
        self.assertEqual(replies[0]["result"]["protocol"], 1)

    def test_malformed_input(self):
        for payload in [struct.pack("<I", 0), struct.pack("<I", 65 * 1024 * 1024),
                        struct.pack("<I", 40) + b"{}", b"\x01\x00",
                        frame({"version": 999, "op": "hello"}), struct.pack("<I", 1) + b"{"]:
            with self.subTest(payload=payload):
                result = self.run_worker(payload)
                self.assertEqual(result.returncode, 1)
                self.assertTrue(result.stderr)


if __name__ == "__main__":
    unittest.main()
