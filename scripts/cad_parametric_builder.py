#!/usr/bin/env python3
"""Build a validated multi-part CAD model from a JSON feature recipe.

The recipe is intentionally generic: image/ML fitting can propose dimensions,
while this deterministic layer owns exact millimetres, primitives, lofts,
booleans, STEP export, and validity checks.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def point_tuple(value):
    return tuple(float(item) for item in value)


def make_feature(cq, feature):
    kind = feature["type"]
    if kind == "box":
        shape = cq.Workplane("XY").box(
            float(feature["length"]), float(feature["width"]), float(feature["height"]),
            centered=tuple(feature.get("centered", [True, True, True])),
        )
        return shape.translate(point_tuple(feature.get("origin", [0, 0, 0])))
    if kind == "cylinder":
        shape = cq.Workplane("XY").cylinder(float(feature["height"]), float(feature["radius"]))
        shape = shape.translate(point_tuple(feature.get("origin", [0, 0, 0])))
        rotation = feature.get("rotation")
        if rotation:
            shape = shape.rotate(point_tuple(rotation[0]), point_tuple(rotation[1]), float(rotation[2]))
        return shape
    if kind == "loft":
        wires = []
        for section in feature["sections"]:
            plane = section.get("plane", "YZ")
            origin = point_tuple(section["origin"])
            points = [point_tuple(point) for point in section["points"]]
            if len(points) < 3:
                raise ValueError("A loft section needs at least three points")
            wires.append(cq.Workplane(plane, origin=origin).polyline(points).close().val())
        solid = cq.Solid.makeLoft(wires, ruled=bool(feature.get("ruled", False)))
        return cq.Workplane("XY").newObject([solid])
    raise ValueError(f"Unsupported CAD feature type: {kind}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("recipe", type=Path)
    parser.add_argument("--step", required=True, type=Path)
    parser.add_argument("--stl", required=True, type=Path)
    args = parser.parse_args()
    try:
        import cadquery as cq
        from cadquery import exporters
    except ImportError as error:
        raise SystemExit(f"CadQuery is not installed: {error}")

    recipe = json.loads(args.recipe.read_text(encoding="utf-8"))
    if recipe.get("units") != "mm":
        raise SystemExit("The CAD recipe must explicitly declare units=mm")
    features = recipe.get("features", [])
    if not features:
        raise SystemExit("The CAD recipe has no features")

    built = []
    for feature in features:
        shape = make_feature(cq, feature)
        if not shape.val().isValid():
            raise SystemExit(f"Invalid feature: {feature.get('name', feature['type'])}")
        built.append((feature, shape))

    result = built[0][1]
    for feature, shape in built[1:]:
        operation = feature.get("operation", "compound")
        if operation == "fuse":
            result = result.union(shape)
        elif operation == "cut":
            result = result.cut(shape)
        elif operation == "compound":
            continue
        else:
            raise SystemExit(f"Unsupported operation: {operation}")
    if not result.val().isValid():
        raise SystemExit("The final CAD result is invalid")

    compound_shapes = [shape.val() for _, shape in built if _.get("operation", "compound") == "compound"]
    if len(compound_shapes) > 1:
        output_shape = cq.Workplane("XY").newObject([cq.Compound.makeCompound(compound_shapes)])
    else:
        output_shape = result
    args.step.parent.mkdir(parents=True, exist_ok=True)
    args.stl.parent.mkdir(parents=True, exist_ok=True)
    exporters.export(output_shape, str(args.step), exporters.ExportTypes.STEP)
    exporters.export(output_shape, str(args.stl), exporters.ExportTypes.STL)
    print(json.dumps({"step": str(args.step), "stl": str(args.stl), "features": len(features), "valid": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
