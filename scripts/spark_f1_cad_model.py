#!/usr/bin/env python3
"""Parametric Spark-style F1 model for paper-craft reconstruction.

This is a deterministic CAD fallback for the supplied sample: body, cockpit,
wheels, front wing, rear wing, and floor are separate solids. Dimensions are
explicit millimetres so image measurements can replace them without changing
the modelling code. Output is STEP for CAD inspection and STL for the existing
mesh unfolding prototype.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def section_wire(cq, x: float, width: float, bottom: float, shoulder: float, roof: float):
    # y,z outline, symmetric across the vehicle centreline.
    outline = [
        (-width / 2, bottom), (width / 2, bottom),
        (width * 0.43, shoulder), (width * 0.30, roof),
        (-width * 0.30, roof), (-width * 0.43, shoulder),
    ]
    return cq.Workplane("YZ", origin=(x, 0, 0)).polyline(outline).close().val()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--params", type=Path, required=True)
    parser.add_argument("--step", type=Path, required=True)
    parser.add_argument("--stl", type=Path, required=True)
    args = parser.parse_args()

    try:
        import cadquery as cq
        from cadquery import exporters
    except ImportError as error:
        raise SystemExit(f"CadQuery is not installed: {error}")

    p = json.loads(args.params.read_text(encoding="utf-8"))
    length = float(p["overallLengthMM"])
    width = float(p["overallWidthMM"])
    height = float(p["overallHeightMM"])
    wheelbase = float(p["wheelbaseMM"])
    wheel_radius = float(p["wheelRadiusMM"])
    wheel_width = float(p["wheelWidthMM"])
    track = float(p["trackMM"])
    floor_z = float(p.get("floorZMM", 2.0))

    stations = [
        (0.0, width * 0.48, floor_z, height * 0.20, height * 0.27),
        (length * 0.10, width * 0.62, floor_z, height * 0.30, height * 0.40),
        (length * 0.30, width * 0.48, floor_z, height * 0.50, height * 0.60),
        (length * 0.52, width * 0.34, floor_z, height * 0.60, height * 0.78),
        (length * 0.70, width * 0.40, floor_z, height * 0.48, height * 0.65),
        (length * 0.88, width * 0.62, floor_z, height * 0.34, height * 0.42),
        (length, width * 0.48, floor_z, height * 0.18, height * 0.25),
    ]
    body_wires = [section_wire(cq, x, w, bottom, shoulder, roof) for x, w, bottom, shoulder, roof in stations]
    body = cq.Solid.makeLoft(body_wires, ruled=False)
    if not body.isValid():
        raise SystemExit("OpenCascade rejected the F1 body loft")
    body_part = cq.Workplane("XY").newObject([body])

    # Cockpit opening, deliberately kept as a separate cut feature for later editing.
    cockpit = cq.Workplane("XY").box(length * 0.25, width * 0.34, height * 0.38, centered=(True, True, False))
    cockpit = cockpit.translate((length * 0.55, 0, height * 0.58))
    body_part = body_part.cut(cockpit)

    parts = [body_part.val()]
    wheel_x = [length * 0.22, length * 0.78]
    for x in wheel_x:
        for y in (-track / 2, track / 2):
            tire = cq.Workplane("XY").cylinder(wheel_width, wheel_radius).rotate((0, 0, 0), (1, 0, 0), 90)
            tire = tire.translate((x, y, wheel_radius + floor_z))
            parts.append(tire.val())

    floor = cq.Workplane("XY").box(length * 0.82, width * 0.58, floor_z, centered=(False, True, False)).translate((length * 0.09, 0, 0))
    parts.append(floor.val())

    front_wing = cq.Workplane("XY").box(length * 0.18, width * 1.08, 1.2, centered=(True, True, False)).translate((length * 0.02, 0, floor_z + height * 0.12))
    rear_wing = cq.Workplane("XY").box(length * 0.13, width * 0.96, 1.6, centered=(True, True, False)).translate((length * 0.91, 0, floor_z + height * 0.62))
    parts.extend([front_wing.val(), rear_wing.val()])

    compound = cq.Compound.makeCompound(parts)
    if not compound.isValid():
        raise SystemExit("OpenCascade rejected the F1 compound")
    result = cq.Workplane("XY").newObject([compound])
    args.step.parent.mkdir(parents=True, exist_ok=True)
    args.stl.parent.mkdir(parents=True, exist_ok=True)
    exporters.export(result, str(args.step), exporters.ExportTypes.STEP)
    exporters.export(result, str(args.stl), exporters.ExportTypes.STL)
    print(json.dumps({"step": str(args.step), "stl": str(args.stl), "parts": len(parts), "valid": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
