#!/usr/bin/env python3
"""Local multi-view reconstruction adapter for Meteor PaperCraft Studio.

This runner intentionally has no hosted API dependency. It uses the optional
MLX-MASt3R package when installed, writes a confidence-filtered point cloud,
and records camera/reconstruction metadata for the native app to consume.
A watertight surface reconstruction is a separate explicit step; silently
turning sparse points into a convex hull would be unsafe for papercraft.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("images", nargs="+", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--variant", default="small", choices=["small", "base"])
    parser.add_argument("--resolution", default=336, type=int, choices=[336, 448, 512])
    parser.add_argument("--confidence-quantile", default=0.35, type=float)
    parser.add_argument("--output-mesh", action="store_true", help="Run local Open3D Poisson reconstruction after point filtering")
    parser.add_argument("--target-faces", default=1800, type=int, help="Target triangle count for papercraft-friendly mesh simplification")
    return parser.parse_args()


def write_ply(path: Path, points) -> int:
    import numpy as np

    array = np.asarray(points, dtype=np.float32).reshape(-1, 3)
    finite = np.isfinite(array).all(axis=1)
    array = array[finite]
    with path.open("w", encoding="ascii") as handle:
        handle.write("ply\nformat ascii 1.0\n")
        handle.write(f"element vertex {len(array)}\n")
        handle.write("property float x\nproperty float y\nproperty float z\nend_header\n")
        for x, y, z in array:
            handle.write(f"{x:.7g} {y:.7g} {z:.7g}\n")
    return len(array)


def write_repaired_mesh(path: Path, points, target_faces: int) -> dict:
    import numpy as np
    import open3d as o3d

    array = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    cloud = o3d.geometry.PointCloud(o3d.utility.Vector3dVector(array))
    cloud = cloud.voxel_down_sample(voxel_size=max(float(np.ptp(array, axis=0).max()) / 350.0, 1e-5))
    cloud.estimate_normals(search_param=o3d.geometry.KDTreeSearchParamHybrid(radius=0.08, max_nn=30))
    cloud.orient_normals_consistent_tangent_plane(30)
    mesh, densities = o3d.geometry.TriangleMesh.create_from_point_cloud_poisson(cloud, depth=8)
    density = np.asarray(densities)
    if len(density):
        keep = density >= np.quantile(density, 0.03)
        mesh.remove_vertices_by_mask(~keep)
    mesh.remove_degenerate_triangles()
    mesh.remove_duplicated_triangles()
    mesh.remove_duplicated_vertices()
    mesh.remove_non_manifold_edges()
    mesh.remove_unreferenced_vertices()
    mesh.orient_triangles()
    if not mesh.is_watertight():
        raise RuntimeError("Poisson reconstruction produced a non-watertight mesh; refusing to send it to unfolding")
    if len(mesh.triangles) > target_faces:
        mesh=mesh.simplify_quadric_decimation(target_number_of_triangles=target_faces)
        mesh.remove_degenerate_triangles()
        mesh.remove_duplicated_triangles()
        mesh.remove_duplicated_vertices()
        mesh.remove_non_manifold_edges()
        mesh.remove_unreferenced_vertices()
        mesh.orient_triangles()
    if not mesh.is_watertight():
        raise RuntimeError("mesh simplification introduced an open or non-manifold surface; refusing to send it to unfolding")
    o3d.io.write_triangle_mesh(str(path), mesh, write_ascii=False)
    return {"vertices": len(mesh.vertices), "triangles": len(mesh.triangles), "targetTriangles": target_faces, "watertight": True}


def main() -> int:
    args = parse_args()
    if len(args.images) < 3:
        print("At least 3 overlapping views are required for local multi-view reconstruction.", file=sys.stderr)
        return 2
    missing = [str(path) for path in args.images if not path.is_file()]
    if missing:
        print("Missing input images: " + ", ".join(missing), file=sys.stderr)
        return 2
    args.output_dir.mkdir(parents=True, exist_ok=True)

    try:
        import mlx.core as mx
        from mlx_mast3r import DuneMast3r
        from mlx_mast3r.cloud_opt import sparse_global_alignment
        from mlx_mast3r.image_pairs import make_pairs
        from mlx_mast3r.utils import load_image
    except ImportError as error:
        if getattr(error, "name", "") == "cv2":
            print("OpenCV is missing. Run scripts/setup-local-3d.sh again to install opencv-python.", file=sys.stderr)
        else:
            print("MLX-MASt3R or one of its dependencies is not installed. Run scripts/setup-local-3d.sh on Apple Silicon again.", file=sys.stderr)
        print(f"Import error: {error}", file=sys.stderr)
        return 3

    model = DuneMast3r.from_pretrained(
        encoder_variant=args.variant,
        resolution=args.resolution,
    )
    imgs_data = []
    for index, path in enumerate(args.images):
        image = load_image(str(path), resolution=args.resolution)
        imgs_data.append({
            "img": mx.array(image).transpose(2, 0, 1)[None],
            "true_shape": image.shape[:2],
            "idx": index,
            "instance": str(path),
        })
    pairs = make_pairs(imgs_data, scene_graph="complete", symmetrize=True)
    result = sparse_global_alignment(
        imgs=[str(path) for path in args.images],
        pairs_in=pairs,
        cache_path=str(args.output_dir / "alignment-cache"),
        model=model,
        lr1=0.07,
        niter1=300,
        lr2=0.01,
        niter2=300,
    )
    points, depths, confidences = result.get_dense_pts3d()

    import numpy as np
    point_array = np.asarray(points).reshape(-1, 3)
    confidence_array = np.asarray(confidences).reshape(-1)
    finite = np.isfinite(point_array).all(axis=1) & np.isfinite(confidence_array)
    point_array = point_array[finite]
    confidence_array = confidence_array[finite]
    if len(point_array) == 0:
        print("The reconstruction produced no finite 3D points.", file=sys.stderr)
        return 4
    threshold = float(np.quantile(confidence_array, args.confidence_quantile))
    selected = point_array[confidence_array >= threshold]
    points_path = args.output_dir / "reconstruction-points.ply"
    point_count = write_ply(points_path, selected)
    mesh_path = None
    mesh_stats = None
    if args.output_mesh:
        try:
            mesh_path = args.output_dir / "reconstruction-repaired.obj"
            mesh_stats = write_repaired_mesh(mesh_path, selected, args.target_faces)
        except ImportError as error:
            if "libusb" in str(error).lower():
                print("Open3D could not load its macOS libusb dependency. Run: brew install libusb", file=sys.stderr)
            else:
                print("--output-mesh requires Open3D in the local environment.", file=sys.stderr)
            print(f"Import error: {error}", file=sys.stderr)
            return 5
        except Exception as error:
            print(f"Refused to emit a mesh: {error}", file=sys.stderr)
            return 6
    metadata = {
        "schema": "meteor.local-multiview.v1",
        "backend": "mlx-mast3r",
        "variant": args.variant,
        "resolution": args.resolution,
        "targetFaces": args.target_faces,
        "imageCount": len(args.images),
        "images": [str(path) for path in args.images],
        "confidenceQuantile": args.confidence_quantile,
        "confidenceThreshold": threshold,
        "pointCount": point_count,
        "surfaceStatus": "watertight-repaired" if mesh_path else "point-cloud-only",
        "mesh": str(mesh_path) if mesh_path else None,
        "meshStats": mesh_stats,
        "nextStep": "import the repaired OBJ into Meteor PaperCraft Studio for unfolding" if mesh_path else "run again with --output-mesh after installing Open3D",
    }
    (args.output_dir / "reconstruction.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    print(json.dumps({"points": str(points_path), "metadata": str(args.output_dir / "reconstruction.json"), "pointCount": point_count}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
