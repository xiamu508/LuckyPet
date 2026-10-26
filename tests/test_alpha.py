import sys
import unittest
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from animation_hd import unmatte_rgba, clean_alpha, decode, metadata


class OriginalAlphaTests(unittest.TestCase):
    def test_opaque_white_artwork_is_preserved(self):
        frame = np.full((8, 8, 4), 255, np.uint8)
        rgb, alpha = unmatte_rgba(frame)
        np.testing.assert_array_equal(rgb, 255)
        np.testing.assert_array_equal(alpha, 1)

    def test_white_preblend_is_reversed(self):
        foreground = np.array([40, 85, 150], np.float32)
        frame = np.empty((3, 3, 4), np.uint8)
        for y, a8 in enumerate([64, 128, 192]):
            a = a8 / 255
            frame[y, :, :3] = np.rint(foreground * a + 255 * (1-a))
            frame[y, :, 3] = a8
        rgb, alpha = unmatte_rgba(frame)
        np.testing.assert_allclose(rgb, np.broadcast_to(foreground, rgb.shape), atol=2.1)
        np.testing.assert_allclose(alpha[:, 0], np.array([64,128,192])/255)

    def test_faint_background_is_fully_transparent(self):
        frame = np.zeros((12, 12, 4), np.uint8)
        frame[..., :3] = 255
        frame[..., 3] = 1
        _, alpha = unmatte_rgba(frame)
        np.testing.assert_array_equal(clean_alpha(alpha), 0)

    def test_bright_low_alpha_fringe_uses_real_neighbor_color(self):
        frame = np.zeros((9, 9, 4), np.uint8)
        frame[3:6, 3:6] = [35, 60, 110, 255]
        frame[2, 4] = [255, 255, 255, 13]
        rgb, _ = unmatte_rgba(frame)
        np.testing.assert_array_equal(rgb[2, 4], [35, 60, 110])

    def test_source_decoder_preserves_real_alpha(self):
        source = ROOT / "assets_raw/idle/待机呼吸休闲.webm"
        frames = decode(source, metadata(source))
        self.assertEqual(frames.shape[1:], (360, 640, 4))
        self.assertGreater(len(frames), 200)
        self.assertEqual(int(frames[0, ..., 3].min()), 0)
        self.assertEqual(int(frames[0, ..., 3].max()), 255)
        self.assertGreater(np.unique(frames[0, ..., 3]).size, 100)


if __name__ == "__main__":
    unittest.main()
