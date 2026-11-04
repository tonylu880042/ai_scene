import math
import unittest

from PIL import Image

from tools.terrarium_sampling import TerrariumAtlas, MissingTerrainTile


def constant_tile(height):
    encoded = int(round((height + 32768) * 256))
    return Image.new('RGB', (256, 256), (encoded >> 16, (encoded >> 8) & 255, encoded & 255))


def lonlat(global_px, global_py, zoom):
    n = 256 * (1 << zoom)
    lon = global_px / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * global_py / n))))
    return lon, lat


class TerrariumSamplingTests(unittest.TestCase):
    def test_cross_tile_interpolation_uses_both_tiles(self):
        atlas = TerrariumAtlas(1, {(0, 0): constant_tile(2), (0, 1): constant_tile(6)})
        lon, lat = lonlat(100.5, 256.0, 1)
        self.assertAlmostEqual(atlas.height(lon, lat), 4, places=6)

    def test_missing_neighbor_fails_instead_of_clamping(self):
        atlas = TerrariumAtlas(1, {(0, 0): constant_tile(2)})
        lon, lat = lonlat(100.5, 256.0, 1)
        with self.assertRaises(MissingTerrainTile):
            atlas.height(lon, lat)

    def test_four_tile_corner_and_antimeridian(self):
        atlas = TerrariumAtlas(1, {(0, 0): constant_tile(2), (1, 0): constant_tile(4),
                                   (0, 1): constant_tile(6), (1, 1): constant_tile(8)})
        lon, lat = lonlat(256, 256, 1)
        self.assertAlmostEqual(atlas.height(lon, lat), 5, places=6)
        lon, lat = lonlat(0, 100.5, 1)
        self.assertAlmostEqual(atlas.height(lon, lat), 3, places=6)

    def test_pixel_centres_and_invalid_coordinates(self):
        atlas = TerrariumAtlas(1, {(0, 0): constant_tile(2)})
        lon, lat = lonlat(100.5, 100.5, 1)
        self.assertAlmostEqual(atlas.height(lon, lat), 2, places=6)
        for lon, lat in [(float('nan'), 0), (0, 90), (181, 0)]:
            with self.assertRaises(ValueError):
                atlas.height(lon, lat)


if __name__ == '__main__':
    unittest.main()
