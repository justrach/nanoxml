#!/usr/bin/env python3
"""Python stdlib baseline: same xlsx->CSV workload as `nanoxml bench full`.

zipfile + xml.etree.ElementTree (C-accelerated) + csv — what a reasonable
Python implementation without third-party deps looks like.
"""
import csv
import io
import sys
import time
import zipfile
import xml.etree.ElementTree as ET

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def col_from_ref(ref):
    col = 0
    for ch in ref:
        if ch.isalpha():
            col = col * 26 + (ord(ch.upper()) - 64)
        else:
            break
    return col - 1 if col else 0


def run(data):
    z = zipfile.ZipFile(io.BytesIO(data))
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        root = ET.fromstring(z.read("xl/sharedStrings.xml"))
        for si in root.iter(NS + "si"):
            shared.append("".join(t.text or "" for t in si.iter(NS + "t")))

    out = io.StringIO()
    wcsv = csv.writer(out, lineterminator="\n")
    root = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
    for row in root.iter(NS + "row"):
        cells = []
        for c in row.iter(NS + "c"):
            col = col_from_ref(c.get("r", ""))
            while len(cells) < col:
                cells.append("")
            t = c.get("t", "n")
            v = c.find(NS + "v")
            raw = v.text if v is not None and v.text else ""
            if t == "s":
                cells.append(shared[int(raw)])
            elif t == "b":
                cells.append("TRUE" if raw.strip() == "1" else "FALSE")
            elif t == "inlineStr":
                is_el = c.find(NS + "is")
                cells.append("".join(tt.text or "" for tt in is_el.iter(NS + "t")) if is_el is not None else "")
            else:
                cells.append(raw)
        wcsv.writerow(cells)
    return len(out.getvalue())


def main():
    path = sys.argv[1]
    iters = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    with open(path, "rb") as f:
        data = f.read()
    n = run(data)  # warmup
    times = []
    for _ in range(iters):
        t0 = time.perf_counter_ns()
        run(data)
        times.append(time.perf_counter_ns() - t0)
    best = min(times)
    avg = sum(times) / len(times)
    print(f"python stdlib (ET+csv): output {n} bytes")
    print(f"  min {best / 1e6:.3f} ms   avg {avg / 1e6:.3f} ms")


if __name__ == "__main__":
    main()
