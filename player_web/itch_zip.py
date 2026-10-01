"""Minimal helper: fetch selected files from a free (min price 0) itch.io zip via HTTP Range, without downloading the whole archive."""
import re, json, struct, zlib, urllib.request, urllib.parse, http.cookiejar, sys

UA = {"User-Agent": "Mozilla/5.0"}

class ItchZip:
    def __init__(self, page, upload_name_hint=None):
        self.cj = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cj))
        self.page = page.rstrip("/")
        self.upload_id = None
        html = self._get(self.page)
        self.csrf = re.search(r'csrf_token" value="([^"]*)', html).group(1)
        r = self._post(self.page + "/download_url", {"csrf_token": self.csrf}, {"X-Requested-With": "XMLHttpRequest"})
        dl = self._get(json.loads(r)["url"])
        self.csrf = re.search(r'csrf_token" value="([^"]*)', dl).group(1)
        self.upload_id = re.search(r'data-upload_id="(\d+)"', dl).group(1)
        self.size = None
        self._probe()

    def _get(self, u):
        return self.op.open(urllib.request.Request(u, headers=UA)).read().decode("utf8", "replace")

    def _post(self, u, data, hdr={}):
        h = dict(UA); h.update(hdr)
        return self.op.open(urllib.request.Request(u, urllib.parse.urlencode(data).encode(), h)).read().decode()

    def _signed(self):
        r = self._post(self.page + f"/file/{self.upload_id}?source=game_download&as_props=1", {"csrf_token": self.csrf})
        return json.loads(r)["url"]

    def _range(self, a, b):  # inclusive
        req = urllib.request.Request(self._signed(), headers={"Range": f"bytes={a}-{b}", **UA})
        r = urllib.request.urlopen(req)
        return r.read(), r.headers.get("Content-Range")

    def _probe(self):
        d, cr = self._range(0, 0)
        self.size = int(cr.split("/")[1])
        tail, _ = self._range(self.size - 70000, self.size - 1)
        i = tail.rfind(b"PK\x05\x06")
        _, _, _, _, n, cdsize, cdoff, _ = struct.unpack("<IHHHHIIH", tail[i:i + 22])
        if cdoff == 0xFFFFFFFF or n == 0xFFFF:  # zip64
            j = tail.rfind(b"PK\x06\x07")
            (eoff,) = struct.unpack("<Q", tail[j + 8:j + 16])
            z, _ = self._range(eoff, eoff + 55)
            n, cdsize, cdoff = struct.unpack("<QQQ", z[32:56])
        cd, _ = self._range(cdoff, cdoff + cdsize - 1)
        self.entries = {}
        p = 0
        for _ in range(n):
            sig, = struct.unpack("<I", cd[p:p + 4])
            (_, _, _, _, meth, _, _, crc, csz, usz, nl, el, cl, _, _, _, off) = struct.unpack("<IHHHHHHIIIHHHHHII", cd[p:p + 46])
            name = cd[p + 46:p + 46 + nl].decode("utf8", "replace")
            ex = cd[p + 46 + nl:p + 46 + nl + el]
            if 0xFFFFFFFF in (csz, usz, off):
                q = 0
                while q < len(ex):
                    tag, sz = struct.unpack("<HH", ex[q:q + 4])
                    if tag == 1:
                        vals = list(struct.unpack("<" + "Q" * (sz // 8), ex[q + 4:q + 4 + sz])); k = 0
                        if usz == 0xFFFFFFFF: usz = vals[k]; k += 1
                        if csz == 0xFFFFFFFF: csz = vals[k]; k += 1
                        if off == 0xFFFFFFFF: off = vals[k]
                    q += 4 + sz
            self.entries[name] = (meth, csz, usz, off)
            p += 46 + nl + el + cl

    def read(self, name):
        meth, csz, usz, off = self.entries[name]
        hdr, _ = self._range(off, off + 29)
        nl, el = struct.unpack("<HH", hdr[26:30])
        data, _ = self._range(off + 30 + nl + el, off + 30 + nl + el + csz - 1)
        return data if meth == 0 else zlib.decompress(data, -15)

if __name__ == "__main__":
    z = ItchZip(sys.argv[1])
    for k, v in z.entries.items(): print(v[2], k)
