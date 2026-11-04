"""Strict, cross-tile bilinear sampling of Web Mercator Terrarium elevation."""

import math


class MissingTerrainTile(ValueError):
    """A required source tile is absent; never substitute a boundary pixel."""


class TerrariumAtlas:
    def __init__(self, zoom, tiles):
        if not isinstance(zoom, int) or not 0 <= zoom <= 24:
            raise ValueError('zoom must be an integer in [0, 24]')
        self.zoom = zoom
        self.tiles = {}
        for key, image in tiles.items():
            if image.size != (256, 256):
                raise ValueError(f'tile {key} must be 256x256 pixels')
            self.tiles[key] = image.convert('RGB').load()

    def _pixel(self, x, y):
        limit = 256 * (1 << self.zoom)
        x %= limit  # adjacent tiles across the antimeridian
        if not 0 <= y < limit:
            raise MissingTerrainTile(f'pixel outside Web Mercator coverage: y={y}')
        key = (x // 256, y // 256)
        if key not in self.tiles:
            raise MissingTerrainTile(f'missing Terrarium tile z={self.zoom} x={key[0]} y={key[1]}')
        r, g, b = self.tiles[key][x % 256, y % 256]
        return r * 256 + g + b / 256 - 32768

    def height(self, lon, lat):
        max_lat = math.degrees(math.atan(math.sinh(math.pi)))
        if not math.isfinite(lon) or not math.isfinite(lat) or not -180 <= lon <= 180 or abs(lat) > max_lat:
            raise ValueError('coordinates outside Web Mercator coverage')
        size = 256 * (1 << self.zoom)
        x = (lon + 180) / 360 * size - 0.5
        y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * size - 0.5
        x0, y0 = math.floor(x), math.floor(y)
        dx, dy = x - x0, y - y0
        value = 0.0
        for px, wx in ((x0, 1 - dx), (x0 + 1, dx)):
            for py, wy in ((y0, 1 - dy), (y0 + 1, dy)):
                weight = wx * wy
                if weight > 1e-15:
                    value += weight * self._pixel(px, py)
        return value
