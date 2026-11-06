#!/usr/bin/env python3
"""Build a valid parametric CAD solid from measured cross-section profiles.

The image/ML stage supplies normalized or millimetre cross-sections; this stage
is deliberately deterministic and uses CadQuery/OpenCascade B-Rep geometry.
It refuses invalid or self-intersecting profiles instead of emitting a mesh
that only looks solid in a viewer.

Input JSON:
{
  "units": "mm",
  "sections": [
    {"x": 0, "outline": [[y, z], ...]},
    {"x": 35, "outline": [[y, z], ...]}
  ]
}
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profiles", type=Path)
    parser.add_argument("--step", required=True, type=Path)
    parser.add_argument("--stl", type=Path)
    args = parser.parse_args()

    try:
        import cadquery as cq
        from cadquery import exporters
    except ImportError as error:
        raise SystemExit(f"CadQuery is not installed. Run scripts/setup-local-3d.sh first.\n{error}")

    payload = json.loads(args.profiles.read_text(encoding="utf-8"))
    sections = sorted(payload.get("sections", []), key=lambda item: float(item["x"]))
    if len(sections) < 2:
        raise SystemExit("At least two cross sections are required")
    if payload.get("units") != "mm":
        raise SystemExit("CAD reconstruction profiles must explicitly use millimetres")

    wires = []
    for section in sections:
        outline = [(float(y), float(z)) for y, z in section["outline"]]
        if len(outline) < 3 or len(set(outline)) < 3:
            raise SystemExit(f"Invalid profile at x={section['x']}")
        if outline[0] != outline[-1]:
            outline.append(outline[0])
        wire = cq.Workplane("YZ", origin=(float(section["x"]), 0, 0)).polyline(outline).close().val()
        if not wire.isClosed():
            raise SystemExit(f"Open profile at x={section['x']}")
        wires.append(wire)

    solid = cq.Solid.makeLoft(wires, ruled=False)
    if not solid.isValid():
        raise SystemExit("OpenCascade rejected the loft as an invalid B-Rep solid")
    result = cq.Workplane("XY").newObject([solid])
    args.step.parent.mkdir(parents=True, exist_ok=True)
    exporters.export(result, str(args.step), exporters.ExportTypes.STEP)
    if args.stl:
        args.stl.parent.mkdir(parents=True, exist_ok=True)
        exporters.export(result, str(args.stl), exporters.ExportTypes.STL)
    print(json.dumps({"step": str(args.step), "stl": str(args.stl) if args.stl else None, "sections": len(sections), "valid": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
