#!/usr/bin/env python3
"""Per-section comparison sheet for the user's sign-off: source frame | scene shot | checklist items and level scores.

  python3 tools/section_sheet.py data/<name>_checklist.json <shots_dir> <scores.json> <out_dir>

checklist (frozen at analysis): {"S01": {"time": "00:30", "ref": "video/<name>_ref/S01.jpg", "L0": [items], ... "L4": [...]}}
scores (per review round):      {"S01": {"L0": [1], "L1": [1, 0.5], ...}}  1 = matches, 0.5 = partly, 0 = no; one per item.
A level not in scores is not reviewed yet. Gates: L0 / L1 >= 90 %, L2-L4 >= 80 %. A section is done when all five
levels pass. Shots are <shots_dir>/<id>.png. Writes sheet_01.png.. (8 sections a page), prints a summary, exits 1 when
a reviewed level fails.
"""
import json, os, sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEVELS = {"L0": 0.9, "L1": 0.9, "L2": 0.8, "L3": 0.8, "L4": 0.8}
MARK = {1: ("○", (27, 120, 55)), 0.5: ("△", (200, 120, 0)), 0: ("×", (200, 30, 30))}
TW, TH, TEXT_W, ROWS = 480, 270, 760, 8
ROW_H = TH + 30


def font(size):  # a CJK-capable macOS font, else Pillow's default
    for p in ("/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc",
              "/System/Library/Fonts/Hiragino Sans GB.ttc", "/Library/Fonts/Arial Unicode.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default(size)


def thumb(path):
    if not os.path.exists(path):
        im = Image.new("RGB", (TW, TH), (60, 60, 60))
        ImageDraw.Draw(im).text((20, TH // 2 - 12), "missing: " + os.path.basename(path), fill=(255, 255, 255), font=font(20))
        return im
    im = Image.open(path).convert("RGB")
    im.thumbnail((TW, TH))  # keeps the aspect: a different shot aspect shows up instead of being stretched
    out = Image.new("RGB", (TW, TH), (30, 30, 30))
    out.paste(im, ((TW - im.width) // 2, (TH - im.height) // 2))
    return out


def score(sid, entry, sc):
    """{level: fraction or None}, items with marks; raises on a score list that doesn't match the frozen items."""
    res, lines = {}, []
    for lv in LEVELS:
        items = entry.get(lv, [])
        marks = sc.get(lv)
        if marks is not None and len(marks) != len(items):
            raise SystemExit(f"{sid} {lv}: {len(marks)} scores for {len(items)} checklist items")
        if marks is not None and any(m not in MARK for m in marks):
            raise SystemExit(f"{sid} {lv}: scores must be 1, 0.5 or 0")
        res[lv] = None if marks is None or not items else sum(marks) / len(items)
        for i, it in enumerate(items):
            lines.append((lv, it, None if marks is None else marks[i]))
    return res, lines


def main():
    checklist = json.load(open(sys.argv[1], encoding="utf-8"))
    shots, scores, out = sys.argv[2], json.load(open(sys.argv[3], encoding="utf-8")), sys.argv[4]
    os.makedirs(out, exist_ok=True)
    f, small, big = font(22), font(19), font(30)
    rows, failed, done = [], False, 0
    for sid, entry in checklist.items():
        res, lines = score(sid, entry, scores.get(sid, {}))
        reviewed = {lv: v for lv, v in res.items() if v is not None}
        bad = [lv for lv, v in reviewed.items() if v < LEVELS[lv]]
        complete = all(res[lv] is not None or not entry.get(lv) for lv in LEVELS)
        status = "FAIL " + ",".join(bad) if bad else ("PASS" if complete and reviewed else "in progress")
        failed |= bool(bad)
        done += status == "PASS"
        print(f"{sid} " + " ".join(f"{lv} {'—' if v is None else f'{v:.0%}'}" for lv, v in res.items()) + f"  {status}")
        rows.append((sid, entry, res, lines, status))
    print(f"{done}/{len(rows)} sections pass")

    for page in range(0, len(rows), ROWS):
        chunk = rows[page:page + ROWS]
        img = Image.new("RGB", (TW * 2 + TEXT_W + 40, 60 + ROW_H * len(chunk)), (250, 250, 247))
        g = ImageDraw.Draw(img)
        g.text((10, 12), f"{os.path.basename(sys.argv[1])}   {done}/{len(rows)} sections pass   "
               "source | scene   ○ 1  △ 0.5  × 0", fill=(0, 0, 0), font=big)
        for r, (sid, entry, res, lines, status) in enumerate(chunk):
            y = 60 + r * ROW_H
            img.paste(thumb(os.path.join(ROOT, entry["ref"])), (10, y))
            img.paste(thumb(os.path.join(shots, sid + ".png")), (TW + 20, y))
            x = TW * 2 + 30
            c = (27, 120, 55) if status == "PASS" else (200, 30, 30) if status.startswith("FAIL") else (90, 90, 90)
            g.text((x, y), f"{sid}  {entry.get('time', '')}  {status}", fill=c, font=f)
            g.text((x, y + 28), "  ".join(f"{lv} {'—' if v is None else f'{v:.0%}'}" for lv, v in res.items()),
                   fill=(0, 0, 0), font=small)
            ty = y + 56
            for lv, it, m in lines:
                if ty > y + TH - 4:
                    g.text((x, ty - 22), "…", fill=(0, 0, 0), font=small)
                    break
                sym, col = MARK[m] if m is not None else ("·", (120, 120, 120))
                g.text((x, ty), f"{sym} {lv} {it}", fill=col, font=small)
                ty += 23
        p = os.path.join(out, f"sheet_{page // ROWS + 1:02d}.png")
        img.save(p)
        print(p)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
