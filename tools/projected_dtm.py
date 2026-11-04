"""Sampling cached South Tyrol WCS 2.5 m DTM GeoTIFFs in route coordinates.

The catalog describes ETRS89 / UTM zone 32N. The WGS84-to-ETRS89 difference
is ignored (a visual preview approximation); no vertical-datum conversion is made.
"""
import math
from pathlib import Path
from PIL import Image


def utm32(lat, lon):
    lat, lon = map(math.radians, (lat, lon))
    a, e, k = 6378137.0, 0.00669438002290, .9996
    ep = e / (1-e)
    n = a / math.sqrt(1-e*math.sin(lat)**2)
    t, c = math.tan(lat)**2, ep*math.cos(lat)**2
    A = math.cos(lat)*(lon-math.radians(9))
    m = a*((1-e/4-3*e**2/64-5*e**3/256)*lat-(3*e/8+3*e**2/32+45*e**3/1024)*math.sin(2*lat)+(15*e**2/256+45*e**3/1024)*math.sin(4*lat)-35*e**3/3072*math.sin(6*lat))
    east = 500000+k*n*(A+(1-t+c)*A**3/6+(5-18*t+t*t+72*c-58*ep)*A**5/120)
    north = k*(m+n*math.tan(lat)*(A*A/2+(5-t+9*c+4*c*c)*A**4/24+(61-58*t+t*t+600*c-330*ep)*A**6/720))
    return east, north


class SouthTyrolDTM:
    def __init__(self, directory, route):
        origin = route['coordinate_system']['origin']
        self.lat = float(origin['lat']); self.lon = float(origin['lon'])
        self.east_per_degree = 111195.08 * math.cos(math.radians(self.lat))
        self.datum = float(route['coordinate_system'].get('elevation_datum_m', 0))
        self.tiles = {}
        for path in Path(directory).glob('*.tif'):
            try: east, north = map(int, path.stem.split('_'))
            except ValueError: continue
            im = Image.open(path)
            matrix = im.tag_v2.get(34264)
            if not matrix or im.mode != 'F': raise ValueError(f'Unsupported DTM raster {path}')
            im.load()
            self.tiles[(east, north)] = (im, matrix)
        if not self.tiles: raise ValueError('No cached DTM rasters')
        self.hits = 0; self.missing = 0

    def sample(self, x, z):
        lat = self.lat-z/111195.08; lon = self.lon+x/self.east_per_degree
        east, north = utm32(lat, lon)
        key = (math.floor(east/2000)*2000, math.floor(north/2000)*2000)
        entry = self.tiles.get(key)
        if entry is None:
            self.missing += 1; return None
        im, mat = entry
        col = max(0, min(im.width-1, math.floor((east-mat[3])/mat[0])))
        row = max(0, min(im.height-1, math.floor((north-mat[7])/mat[5])))
        value = float(im.getpixel((col, row)))
        if not math.isfinite(value) or value < -1000:
            self.missing += 1; return None
        self.hits += 1
        return value-self.datum

    def sample_bilinear(self, x, z):
        """Bilinear raster heights; rejects missing data and clamps only at tile edges."""
        lat = self.lat-z/111195.08; lon = self.lon+x/self.east_per_degree
        east, north = utm32(lat, lon)
        key = (math.floor(east/2000)*2000, math.floor(north/2000)*2000)
        entry = self.tiles.get(key)
        if entry is None:
            self.missing += 1; return None
        im, mat = entry
        x = max(0., min(im.width-1., (east-mat[3])/mat[0]-.5))
        y = max(0., min(im.height-1., (north-mat[7])/mat[5]-.5))
        i, j = math.floor(x), math.floor(y)
        ii, jj = min(i+1,im.width-1), min(j+1,im.height-1)
        values = [float(im.getpixel((i,j))),float(im.getpixel((ii,j))),float(im.getpixel((i,jj))),float(im.getpixel((ii,jj)))]
        if any(not math.isfinite(v) or v < -1000 for v in values):
            self.missing += 1; return None
        fx,fy=x-i,y-j
        value = (1-fy)*((1-fx)*values[0]+fx*values[1])+fy*((1-fx)*values[2]+fx*values[3])
        self.hits += 1
        return value-self.datum
