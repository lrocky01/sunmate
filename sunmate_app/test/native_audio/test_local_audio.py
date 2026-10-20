"""Local Core Audio integration tests; synthetic inputs only, no phone/network."""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tempfile
import unittest
import wave

HERE = Path(__file__).resolve().parent
CORE = HERE.parents[1] / 'ios' / 'Runner' / 'RecorderLocalAudio.swift'


def crc(data):
    value = 0
    for byte in data:
        value ^= byte << 24
        for _ in range(8):
            value = ((value << 1) ^ (0x04c11db7 if value & 0x80000000 else 0)) & 0xffffffff
    return value


def page(payload, number, granule, flags=0):
    laces = [255] * (len(payload) // 255) + [len(payload) % 255]
    if not payload:
        laces = []
    data = bytearray(b'OggS' + bytes([0, flags]) + struct.pack('<QIII', granule, 7, number, 0)
                     + bytes([len(laces)]) + bytes(laces) + payload)
    struct.pack_into('<I', data, 22, crc(data))
    return data


def synthetic_ogg(channels=1, toc=0xf8, count=20):
    # Opus' documented 20ms silence packet. Matches OggOpusStream page layout.
    head = b'OpusHead' + bytes([1, channels]) + struct.pack('<HIhB', 0, 16000, 0, 0)
    tags = b'OpusTags' + struct.pack('<I', 4) + b'test' + struct.pack('<I', 0)
    chunks = [page(head, 0, 0, 2), page(tags, 1, 0)]
    chunks += [page(bytes([toc, 0xff, 0xfe]), i + 2, (i + 1) * 960) for i in range(count)]
    chunks += [page(b'', count + 2, count * 960, 4)]
    return b''.join(chunks)


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'requires macOS Core Audio and Swift')
class NativeAudioTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='sunmate-audio-build-')
        cls.binary = Path(cls.build.name) / 'prepare'
        result = subprocess.run(['swiftc', str(CORE), str(HERE / 'main.swift'), '-o', str(cls.binary)], capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr.decode())

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sunmate-audio-test-')
        self.root = Path(self.temp.name).resolve()
        self.relative = 'recorder_long_audio_v1/TEST/s1/source.ogg'
        self.source = self.root / self.relative
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(synthetic_ogg())

    def tearDown(self):
        self.temp.cleanup()

    def prepare(self, success=True, relative=None):
        result = subprocess.run([str(self.binary), str(self.root), relative or self.relative], capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        return json.loads(result.stdout) if success else result

    def verify_playback(self, relative, success=True):
        result = subprocess.run([str(self.binary), str(self.root), relative, 'verify-playback'], capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())

    def test_zero_preskip_real_decode_and_checked_cache(self):
        original = self.source.read_bytes()
        result = self.prepare()
        self.assertEqual(result['sampleRate'], 16000)
        self.assertEqual(result['frames'], 6400)
        self.assertEqual(result['durationMs'], 400)
        with wave.open(str(self.root / result['relativePath'])) as wav:
            self.assertEqual(wav.getnchannels(), 1)
            self.assertEqual(wav.getsampwidth(), 2)
            self.assertEqual(wav.getnframes(), 6400)
        self.assertEqual(self.prepare(), result)
        self.verify_playback(result['relativePath'])
        self.assertEqual(self.source.read_bytes(), original)
        proof = json.loads((self.root / result['relativePath']).with_suffix('.json').read_text())
        self.assertEqual(proof['sourceSHA256'], hashlib.sha256(original).hexdigest())

    @unittest.skipUnless(shutil.which('ffmpeg'), 'requires ffmpeg to synthesize independent Opus')
    def test_pcm_sine_opus_prepare_wav_has_expected_nonzero_samples(self):
        result = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                                 'sine=frequency=440:duration=1', '-ar', '16000', '-ac', '1',
                                 '-c:a', 'libopus', '-frame_duration', '20', '-y', str(self.source)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        result = self.prepare()
        self.assertEqual(result['frames'], 16000)
        with wave.open(str(self.root / result['relativePath'])) as wav:
            pcm = wav.readframes(wav.getnframes())
        samples = struct.unpack('<' + 'h' * (len(pcm) // 2), pcm)
        self.assertGreater(max(samples), 1000)
        self.assertLess(min(samples), -1000)

    def test_bad_crc_rejected_without_touching_original(self):
        data = bytearray(self.source.read_bytes())
        data[-1] ^= 1
        self.source.write_bytes(data)
        self.prepare(False)
        self.assertEqual(self.source.read_bytes(), data)
        self.assertFalse(list(self.source.parent.glob('playback-*.wav')))

    def test_missing_end_page_rejected(self):
        self.source.write_bytes(self.source.read_bytes()[:-27])
        self.prepare(False)
        self.assertFalse(list(self.source.parent.glob('playback-*.wav')))

    def test_stereo_and_inconsistent_toc_granules_rejected(self):
        self.source.write_bytes(synthetic_ogg(channels=2))
        self.prepare(False)
        self.source.write_bytes(synthetic_ogg(toc=0xf0))  # Opus CELT 10ms, not this recorder profile.
        self.prepare(False)

    def test_mixed_10_20_40_60ms_packet_samples_are_preserved(self):
        original = synthetic_ogg()
        # Reuse the separately generated headers, then real Opus CBR frame packing.
        first_page_length = 27 + original[26] + 19
        tags_length = 27 + original[first_page_length + 26] + 20
        headers = original[:first_page_length + tags_length]
        packets = [(bytes([0xf0,255,254]), 480),
                   (bytes([0xf8,255,254]), 960),
                   (bytes([0xf9,255,254,255,254]), 1920),
                   (bytes([0xfb,3,255,254,255,254,255,254]), 2880)]
        chunks = [headers]
        granule = 0
        for index, (payload, samples) in enumerate(packets):
            granule += samples
            chunks.append(page(payload, index + 2, granule))
        chunks.append(page(b'', len(packets) + 2, granule, 4))
        self.source.write_bytes(b''.join(chunks))
        result = self.prepare()
        self.assertEqual(result['frames'], 2080)
        self.assertEqual(result['durationMs'], 130)

    def test_corrupted_cached_wav_is_never_replaced_or_accepted(self):
        result = self.prepare()
        wav = self.root / result['relativePath']
        data = bytearray(wav.read_bytes())
        data[-1] ^= 1
        wav.write_bytes(data)
        self.verify_playback(result['relativePath'], success=False)
        self.prepare(False)
        self.assertEqual(wav.read_bytes(), data)

    def test_many_packets_use_streamed_packet_table(self):
        self.source.write_bytes(synthetic_ogg(count=30000))
        result = self.prepare()
        self.assertEqual(result['frames'], 9600000)
        self.assertEqual(result['durationMs'], 600000)
        self.verify_playback(result['relativePath'])
        # Packet data and varint tables are work files only, closed and cleaned.
        self.assertFalse(list(self.source.parent.glob('work-*')))

    def test_playback_rejects_changed_proof_frames_and_source_identity(self):
        result = self.prepare()
        manifest = (self.root / result['relativePath']).with_suffix('.json')
        proof = json.loads(manifest.read_text())
        proof['frames'] += 1
        manifest.write_text(json.dumps(proof))
        self.verify_playback(result['relativePath'], success=False)
        proof['frames'] -= 1
        proof['sourceSHA256'] = '0' * 64
        manifest.write_text(json.dumps(proof))
        self.verify_playback(result['relativePath'], success=False)

    def test_missing_cache_proof_is_not_treated_as_success(self):
        result = self.prepare()
        (self.root / result['relativePath']).with_suffix('.json').unlink()
        self.verify_playback(result['relativePath'], success=False)
        self.prepare(False)

    def test_traversal_and_symbolic_link_refused(self):
        self.prepare(False, '../source.ogg')
        self.prepare(False, '/tmp/source.ogg')
        outside = self.root / 'outside.ogg'
        outside.write_bytes(synthetic_ogg())
        self.source.unlink()
        self.source.symlink_to(outside)
        self.prepare(False)
        self.assertEqual(outside.read_bytes(), synthetic_ogg())


if __name__ == '__main__':
    unittest.main()
