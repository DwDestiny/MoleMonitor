#!/usr/bin/env python3
# check_sprites.py - gate W11 for the Bichon action strips (docs/DESIGN_V2.md 11.5, 13.3).
# Input: Resources/DogSprites/manifest.json, the strip PNG files next to it, and the reference
#        Resources/DogArt/dog_stand.png. Paths come from this script's location.
# Output: one line per check with the measured numbers, a summary, exit code 0 (all pass) or 1.
#         With --sheet-dir DIR: contact sheets (white, dark, color background) for the blind review.
# Needs Pillow and numpy (local Python or CI Python only). The app has no dependency on this script.
#
# Definitions (fixed here, so the numbers are reproducible):
#   subject      pixels with alpha >= 128 (alpha >= 0.5, same rule as IconMetrics.xorRatio)
#   XOR ratio    count(a != b) / max(count(a), count(b)), on the stored 320 x 240 frames, no realignment
#   fur color    mean CIELAB of the subject; difference = CIE76 delta E
#   dark spot    subject pixels with L* < 30, 8-connected component of >= 20 px, centroid in the face box
#   hue clusters subject pixels with chroma C* >= 8, 10-degree hue bins; a bin with >= 0.2 % of the subject
#                pixels is occupied; one cluster = one peak of the circular histogram; two peaks merge when
#                the valley between them stays above half of the lower peak
import argparse
import json
import pathlib
import sys

try:
    import numpy as np
    from PIL import Image, ImageDraw
except ImportError as e:  # the gate needs a Python with Pillow and numpy (a venv on Linux, the CI Python on macOS)
    sys.exit("check_sprites.py needs Pillow and numpy: %s" % e)

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPRITES = ROOT / "Resources" / "DogSprites"
REFERENCE = ROOT / "Resources" / "DogArt" / "dog_stand.png"

FRAME_W, FRAME_H = 320, 240
FOOT_Y, FOOT_TOL = 230, 2
FUR_DE_MAX = 6.0
HEIGHT_TOL = 0.06
ADJ_MIN, ADJ_MAX = 0.02, 0.25
DISTINCT_MIN = 0.20
DARK_L, DARK_MIN_PX, FACE_SPOTS = 30.0, 20, 3
HUE_CHROMA, HUE_BIN_SHARE, HUE_CLUSTERS_MAX = 8.0, 0.002, 6
BUNDLE_MAX_BYTES = 4 * 1024 * 1024
GENERATED_STRIPS = 9

# Table 4.3 of docs/DESIGN_V2.md: the first-release actions and their frame counts (59 frames).
# stand_up has 6 frames at 18 fps (4.3 lists 4 at 12 fps, same 0.33 s), so each step stays below 0.25.
EXPECTED = {
    "lie_idle": 6, "walk": 8, "trot": 8, "sprint": 6, "sniff": 8,
    "sit_gray": 1, "stand_up": 6, "wag": 6, "pant_lie": 6, "notice": 4,
}


def srgb_to_lab(rgb):
    c = rgb / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def label8(mask):
    """8-connected component labels without scipy: returns (labels, count)."""
    h, w = mask.shape
    lab = np.zeros((h, w), dtype=np.int32)
    n = 0
    ys, xs = np.nonzero(mask)
    for y0, x0 in zip(ys, xs):
        if lab[y0, x0]:
            continue
        n += 1
        stack = [(y0, x0)]
        lab[y0, x0] = n
        while stack:
            y, x = stack.pop()
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < h and 0 <= xx < w and mask[yy, xx] and not lab[yy, xx]:
                        lab[yy, xx] = n
                        stack.append((yy, xx))
    return lab, n


def xor_ratio(a, b):
    return float((a != b).sum()) / max(int(a.sum()), int(b.sum()), 1)


class Frame:
    def __init__(self, rgba):
        self.rgba = rgba
        self.mask = rgba[..., 3] >= 128
        self._lab = None

    @property
    def lab(self):
        if self._lab is None:
            self._lab = srgb_to_lab(self.rgba[..., :3].astype(float))
        return self._lab

    def mean_lab(self):
        return self.lab[self.mask].mean(0)

    def height(self):
        ys = np.nonzero(self.mask)[0]
        return int(ys.max() - ys.min() + 1) if len(ys) else 0

    def lowest(self):
        ys = np.nonzero(self.mask)[0]
        return int(ys.max()) if len(ys) else -1

    def dark_spots(self, box):
        x, y, w, h = box
        dark = self.mask & (self.lab[..., 0] < DARK_L)
        lab, n = label8(dark)
        spots = []
        for i in range(1, n + 1):
            yy, xx = np.nonzero(lab == i)
            if len(yy) < DARK_MIN_PX:
                continue
            cx, cy = xx.mean(), yy.mean()
            if x <= cx < x + w and y <= cy < y + h:
                spots.append(len(yy))
        return spots

    def hue_clusters(self):
        lab = self.lab[self.mask]
        chroma = np.hypot(lab[:, 1], lab[:, 2])
        hue = (np.degrees(np.arctan2(lab[:, 2], lab[:, 1])) + 360) % 360
        hist = np.bincount((hue[chroma >= HUE_CHROMA] // 10).astype(int), minlength=36)[:36]
        floor = HUE_BIN_SHARE * max(len(lab), 1)
        h = np.where(hist >= floor, hist, 0).astype(float)
        # peaks: occupied bins higher than both circular neighbours (plateaus count once)
        peaks = [k for k in range(36) if h[k] > 0 and h[k] >= h[k - 1] and h[k] > h[(k + 1) % 36]]
        if len(peaks) <= 1:
            return len(peaks) if h.any() else 0
        # two neighbouring peaks are one cluster unless the valley between them is below half of the lower peak
        clusters = len(peaks)
        for i, p in enumerate(peaks):
            q = peaks[(i + 1) % len(peaks)]
            span = [(p + s) % 36 for s in range(((q - p) % 36) + 1)]
            if min(h[s] for s in span) > 0.5 * min(h[p], h[q]):
                clusters -= 1
        return max(clusters, 1)


class Report:
    def __init__(self):
        self.rows = []

    def add(self, name, ok, detail):
        self.rows.append((name, ok, detail))
        print("%s  %-22s %s" % ("PASS" if ok else "FAIL", name, detail))

    @property
    def ok(self):
        return all(r[1] for r in self.rows)


def load_strip(path, count):
    im = Image.open(path).convert("RGBA")
    if im.size != (FRAME_W * count, FRAME_H):
        return None, "size %dx%d, expected %dx%d" % (im.size[0], im.size[1], FRAME_W * count, FRAME_H)
    arr = np.array(im)
    return [Frame(arr[:, k * FRAME_W:(k + 1) * FRAME_W]) for k in range(count)], ""


def contact_sheets(actions, frames, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    cols = max(len(frames[a["name"]]) for a in actions)
    label_w = 120
    for name, bg, fg in (("white", (255, 255, 255), (60, 60, 60)), ("dark", (28, 30, 38), (220, 220, 220)),
                         ("color", (118, 152, 196), (255, 255, 255))):
        sheet = Image.new("RGBA", (label_w + cols * FRAME_W, len(actions) * FRAME_H), bg + (255,))
        draw = ImageDraw.Draw(sheet)
        for r, a in enumerate(actions):
            draw.text((8, r * FRAME_H + FRAME_H // 2 - 6), "%s (%d)" % (a["name"], len(frames[a["name"]])), fill=fg)
            for k, f in enumerate(frames[a["name"]]):
                sheet.alpha_composite(Image.fromarray(f.rgba), (label_w + k * FRAME_W, r * FRAME_H))
        p = out_dir / ("sprites_%s.png" % name)
        sheet.convert("RGB").save(p)
        print("sheet  %s" % p)


def main():
    ap = argparse.ArgumentParser(description="Gate W11: Bichon action strips")
    ap.add_argument("--sheet-dir", help="write contact sheets (white, dark, color) to this directory")
    ap.add_argument("--json", help="write the measured values to this JSON file")
    args = ap.parse_args()
    rep = Report()
    values = {}

    manifest_path = SPRITES / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, ValueError) as e:
        rep.add("manifest", False, "cannot read %s: %s" % (manifest_path.name, e))
        return 1
    actions = manifest.get("actions", [])
    names = [a.get("name") for a in actions]
    counts = {a.get("name"): a.get("frames") for a in actions}
    total = sum(int(a.get("frames", 0)) for a in actions)
    generated = sum(1 for a in actions if a.get("generated"))
    ok = counts == EXPECTED and total == 59 and generated == GENERATED_STRIPS and len(names) == len(set(names))
    ok = ok and manifest.get("frameWidth") == FRAME_W and manifest.get("frameHeight") == FRAME_H
    rep.add("manifest", ok, "%d actions, %d frames (expected 10, 59), %d generated strips (expected %d)"
            % (len(actions), total, generated, GENERATED_STRIPS))

    frames = {}
    for a in actions:
        path = SPRITES / a.get("file", "")
        if not path.is_file():
            rep.add("file " + a["name"], False, "missing %s" % a.get("file"))
            continue
        fr, err = load_strip(path, int(a["frames"]))
        if fr is None:
            rep.add("file " + a["name"], False, err)
            continue
        frames[a["name"]] = fr
    rep.add("files", len(frames) == len(actions), "%d of %d strips read, each frame %dx%d px"
            % (len(frames), len(actions), FRAME_W, FRAME_H))
    if len(frames) != len(actions) or not REFERENCE.is_file():
        if not REFERENCE.is_file():
            rep.add("reference", False, "missing %s" % REFERENCE.name)
        print("RESULT FAIL (files missing, later checks skipped)")
        return 1

    ref = Frame(np.array(Image.open(REFERENCE).convert("RGBA")))
    ref_lab, ref_h = ref.mean_lab(), ref.height()
    live = [a for a in actions if a["name"] in frames]

    # 1 fur color
    worst = (0.0, "")
    for a in live:
        for k, f in enumerate(frames[a["name"]]):
            de = float(np.linalg.norm(f.mean_lab() - ref_lab))
            values.setdefault("furDeltaE", {})["%s/%d" % (a["name"], k)] = round(de, 2)
            worst = max(worst, (de, "%s/%d" % (a["name"], k)))
    rep.add("fur color", worst[0] <= FUR_DE_MAX, "max delta E %.2f at %s (limit %.1f, reference L*a*b* %.1f %.1f %.1f)"
            % (worst[0], worst[1], FUR_DE_MAX, ref_lab[0], ref_lab[1], ref_lab[2]))

    # 2 standing height
    worst, n = (0.0, ""), 0
    for a in live:
        for k in a.get("standingFrames", []):
            d = abs(frames[a["name"]][k].height() - ref_h) / ref_h
            n += 1
            worst = max(worst, (d, "%s/%d h=%d" % (a["name"], k, frames[a["name"]][k].height())))
    rep.add("standing height", n > 0 and worst[0] <= HEIGHT_TOL, "%d standing frames, max difference %.1f %% at %s (reference h=%d, limit %.0f %%)"
            % (n, worst[0] * 100, worst[1], ref_h, HEIGHT_TOL * 100))

    # 3 foot line
    bad, n = [], 0
    for a in live:
        for k in a.get("groundedFrames", []):
            y = frames[a["name"]][k].lowest()
            n += 1
            if abs(y - FOOT_Y) > FOOT_TOL:
                bad.append("%s/%d y=%d" % (a["name"], k, y))
    rep.add("foot line", n > 0 and not bad, "%d grounded frames, lowest pixel y = %d +- %d; outside: %s"
            % (n, FOOT_Y, FOOT_TOL, ", ".join(bad) or "none"))

    # 4 adjacent frames and 5 loop seam
    adj_bad, seam_bad, adj_all, seams = [], [], [], {}
    for a in live:
        fr = frames[a["name"]]
        ms = [f.mask for f in fr]
        steps = [xor_ratio(ms[k], ms[k + 1]) for k in range(len(ms) - 1)]
        values.setdefault("adjacentXOR", {})[a["name"]] = [round(v, 3) for v in steps]
        adj_all += steps
        for k, v in enumerate(steps):
            if not ADJ_MIN <= v <= ADJ_MAX:
                adj_bad.append("%s %d-%d %.3f" % (a["name"], k, k + 1, v))
        if len(ms) > 1 and (a.get("playback") == "loop" or int(a.get("repeat", 1)) > 1):
            v = xor_ratio(ms[-1], ms[0])
            seams[a["name"]] = round(v, 3)
            if not ADJ_MIN <= v <= ADJ_MAX:
                seam_bad.append("%s %.3f" % (a["name"], v))
    values["seamXOR"] = seams
    rep.add("adjacent frames", not adj_bad, "%d pairs, range %.3f-%.3f (limit %.2f-%.2f); outside: %s"
            % (len(adj_all), min(adj_all), max(adj_all), ADJ_MIN, ADJ_MAX, "; ".join(adj_bad) or "none"))
    rep.add("loop seam", not seam_bad, "%d loops: %s; outside: %s"
            % (len(seams), ", ".join("%s %.3f" % kv for kv in seams.items()), "; ".join(seam_bad) or "none"))

    # 6 face
    bad, n = [], 0
    for a in live:
        boxes = a.get("faceBoxes", [])
        for k, f in enumerate(frames[a["name"]]):
            n += 1
            if k >= len(boxes):
                bad.append("%s/%d no box" % (a["name"], k))
                continue
            spots = f.dark_spots(boxes[k])
            if len(spots) != FACE_SPOTS:
                bad.append("%s/%d %d spots" % (a["name"], k, len(spots)))
    rep.add("face", not bad, "%d frames, %d dark spots (two eyes, one nose) in each face box; wrong: %s"
            % (n, FACE_SPOTS, "; ".join(bad) or "none"))

    # 7 actions differ (representative frames)
    reps = []
    for a in live:
        r = int(a.get("representativeFrame", a.get("restFrame", 0)))
        reps.append((a["name"], frames[a["name"]][r].mask))
    pairs = {}
    for i in range(len(reps)):
        for j in range(i + 1, len(reps)):
            pairs["%s/%s" % (reps[i][0], reps[j][0])] = xor_ratio(reps[i][1], reps[j][1])
    values["distinctXOR"] = {k: round(v, 3) for k, v in pairs.items()}
    low = sorted((v, k) for k, v in pairs.items())
    rep.add("actions differ", len(pairs) == 45 and low[0][0] >= DISTINCT_MIN,
            "%d pairs of representative frames, smallest: %s (limit %.2f); below: %s"
            % (len(pairs), ", ".join("%s %.3f" % (k, v) for v, k in low[:3]), DISTINCT_MIN,
               ", ".join("%s %.3f" % (k, v) for v, k in low if v < DISTINCT_MIN) or "none"))

    # 8 color count
    worst = (0, "")
    for a in live:
        for k, f in enumerate(frames[a["name"]]):
            worst = max(worst, (f.hue_clusters(), "%s/%d" % (a["name"], k)))
    rep.add("hue clusters", worst[0] <= HUE_CLUSTERS_MAX, "max %d at %s (limit %d)" % (worst[0], worst[1], HUE_CLUSTERS_MAX))

    # bundle size (11.3)
    size = sum(p.stat().st_size for p in SPRITES.glob("*.png"))
    rep.add("bundle size", size <= BUNDLE_MAX_BYTES, "%d PNG files, %.2f MB (limit 4 MB)"
            % (len(list(SPRITES.glob("*.png"))), size / 1048576))

    # 9 blind review: the contact sheets are the input for a person or the Fable review
    if args.sheet_dir:
        contact_sheets(live, frames, pathlib.Path(args.sheet_dir))
    else:
        print("note   blind review: run with --sheet-dir DIR to write the contact sheets")
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(values, indent=1, sort_keys=True))

    passed = sum(1 for r in rep.rows if r[1])
    print("RESULT %s (%d of %d checks pass)" % ("PASS" if rep.ok else "FAIL", passed, len(rep.rows)))
    return 0 if rep.ok else 1


if __name__ == "__main__":
    sys.exit(main())
