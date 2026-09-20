"""Exercise framing failures without starting Vulkan or loading the runtime."""
import json
import struct
import subprocess
import sys
import unittest

WORKER = sys.argv.pop(1)
MAX_FRAME_BYTES = 64 * 1024 * 1024
MORE_FRAMES = 0x80000000


def frame(message, chunk_size=MAX_FRAME_BYTES):
    payload = json.dumps(message, ensure_ascii=False).encode()
    chunks = []
    for offset in range(0, len(payload), chunk_size):
        chunk = payload[offset:offset + chunk_size]
        flags = len(chunk) | (MORE_FRAMES if offset + len(chunk) < len(payload) else 0)
        chunks.append(struct.pack("<I", flags) + chunk)
    return b"".join(chunks)


def replies(stream):
    messages = []
    payload = bytearray()
    while stream:
        flags, = struct.unpack("<I", stream[:4])
        size = flags & ~MORE_FRAMES
        assert 0 < size <= MAX_FRAME_BYTES and len(stream) >= 4 + size
        payload.extend(stream[4:4 + size])
        stream = stream[4 + size:]
        if not flags & MORE_FRAMES:
            messages.append(json.loads(payload))
            payload.clear()
    assert not payload, "Incomplete response"
    return messages


class ProtocolTests(unittest.TestCase):
    def run_worker(self, payload):
        return subprocess.run([WORKER], input=payload, capture_output=True, timeout=30)

    def test_session_and_recoverable_error(self):
        messages = [{"id": 1, "version": 2, "op": "hello"},
                    {"id": 2, "version": 2, "op": "unknown"},
                    {"id": 3, "version": 2, "op": "shutdown"}]
        result = self.run_worker(b"".join(map(frame, messages)))
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = replies(result.stdout)
        self.assertEqual([r["id"] for r in responses], [1, 2, 3])
        self.assertEqual([r["ok"] for r in responses], [True, False, True])
        self.assertEqual(responses[0]["result"]["protocol"], 2)

    def test_large_transfer_and_reply(self):
        # A large unknown operation is echoed in the error. This exercises both
        # directions past 64 MiB without requiring a GPU or Remix runtime.
        operation = "x" * (MAX_FRAME_BYTES + 1024) + "終"
        payload = frame({"version": 2, "op": operation, "id": 7})
        payload += frame({"version": 2, "op": "hello", "id": 8})
        result = self.run_worker(payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = replies(result.stdout)
        self.assertEqual([r["id"] for r in responses], [7, 8])
        self.assertEqual(responses[0]["error"], "Unknown renderer operation: " + operation)
        self.assertTrue(responses[1]["ok"])

    def test_split_utf8(self):
        message = {"version": 2, "op": "材質🌲", "id": 9}
        result = self.run_worker(frame(message, chunk_size=1))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(replies(result.stdout)[0]["error"], "Unknown renderer operation: 材質🌲")

    def test_malformed_input(self):
        unfinished = struct.pack("<I", MORE_FRAMES | 1) + b"{"
        for payload in [struct.pack("<I", 0), struct.pack("<I", MAX_FRAME_BYTES + 1),
                        struct.pack("<I", 40) + b"{}", b"\x01\x00",
                        frame({"version": 1, "op": "hello"}), struct.pack("<I", 1) + b"{",
                        unfinished, unfinished + b"\x01\x00",
                        unfinished + struct.pack("<I", 5) + b"}",
                        unfinished + struct.pack("<I", MORE_FRAMES),
                        unfinished + struct.pack("<I", MAX_FRAME_BYTES + 1)]:
            with self.subTest(payload=payload):
                result = self.run_worker(payload)
                self.assertEqual(result.returncode, 1)
                self.assertTrue(result.stderr)


if __name__ == "__main__":
    unittest.main()
