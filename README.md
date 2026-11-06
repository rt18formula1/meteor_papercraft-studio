# Meteor PaperCraft Studio

Native macOS prototype for creating a printable PDF papercraft template from a photo. All image processing is local and rule-based; the app does not use generative AI or upload photos.

## Build

Requirements: Apple Silicon Mac and the Xcode Command Line Tools (full Xcode is not required).

```sh
./scripts/build-app.sh
```

The app bundle is created at `dist/Meteor PaperCraft Studio.app`. The distributable build bundles the local Python environment, MLX-MASt3R dependencies, Open3D, CadQuery, and the Homebrew libusb dylib into the `.app`; customers do not need Python, Homebrew, a terminal setup, or an external API. Build the distributable on the target Apple Silicon Mac after running `scripts/setup-local-3d.sh` once for the developer machine. Copy the complete `.app` bundle to a writable external drive and launch it from there. This build targets Apple Silicon (arm64) and macOS 13 or later.

To produce the customer archive after the one-time developer setup, run `./scripts/package-distribution.sh`. It creates `dist/Meteor-PaperCraft-Studio-macOS-arm64.zip`; the customer only unzips it and opens the app.

The app is ad-hoc signed for local use, not notarized for public distribution. Gatekeeper may require the user to approve opening it, especially after downloading or copying it from another Mac. A commercial release should use a Developer ID signature and Apple notarization.

## Current prototype behavior

### Optional local AI multi-view backend

On Apple Silicon, run `scripts/setup-local-3d.sh` once to create the local MLX-MASt3R/Open3D/CadQuery/OpenCV environment. The script also installs or repairs Homebrew `libusb`, which the macOS Open3D wheel may load as a native dependency. MLX-MASt3R requires Python 3.11 or newer; the setup script detects Python 3.11–3.13, recreates an older Python 3.9 virtual environment, and can install Homebrew `python@3.12` when Homebrew is available. MLX-MASt3R is installed from its GitHub repository because it is not published as a PyPI package. OpenCV is installed explicitly as `opencv-python` because MLX-MASt3R imports `cv2` during startup. The app's `ローカルAIで3D…` action reconstructs the loaded views locally, filters points by confidence, runs Poisson surface reconstruction, removes degenerate/non-manifold geometry, simplifies the result toward a papercraft-friendly 1,800-triangle target, rejects non-watertight output, and sends the repaired OBJ to the mesh unfolder. For CAD-grade reconstruction, `scripts/cad_profile_loft.py` converts measured millimetre cross-sections into an OpenCascade B-Rep loft and exports STEP/STL; this is the deterministic CAD stage rather than a guessed convex hull. Model weights are cached locally after the first setup/run; no hosted inference API is used. This backend is intentionally separate from native RealityKit Object Capture because the two pipelines have different failure modes.

The CAD layer is not F1-specific. `scripts/cad_parametric_builder.py` accepts a generic millimetre recipe containing boxes, cylinders, loft sections, and fuse/cut/compound operations. The Spark F1 generator is only a validation fixture; future objects use the same feature recipe and CAD kernel.

The supplied `Meteor PaperCraft Studio_Sample-Data/F1-Sample.meteorcraft` project preselects the five sample photos. Open it with “プロジェクトを開く…” after copying the project folder to the same location on the Mac.

1. Add local photos, add an entire image folder, or paste a direct image URL, then select a view. Local image processing is the default; URL import necessarily downloads the image once, with a size and pixel limit, and then processing remains local.
2. The app estimates a background color from the image border, thresholds pixels by color distance, prioritizes a substantial central foreground component, and follows its boundary while retaining practical concavities. For difficult backgrounds, trace the outline by clicking around the object and confirm it.
3. Adjust threshold, desired width, and extrusion depth.
4. Export a vector PDF on landscape A4 with two silhouette faces, a side band, and glue tabs. Red lines are cuts; blue dashed lines are folds. Large patterns tile across pages at 100% scale with a 10 mm overlap. Every page includes a 100 mm calibration bar: print at 100% and measure it before producing a saleable model.
5. On supported Macs, isolate each loaded view locally using macOS Vision's on-device foreground mask when available, then run local RealityKit photogrammetry to estimate camera scale/pose and fuse the masked views into a medium-detail USDZ model. The USDZ can then be sent through the mesh unfolding workflow.
6. Import a USDZ, OBJ, or STL mesh and unfold its triangle faces into an A4 tiled PDF at the selected model width. The deterministic unfolding joins faces where they fit without overlap, cuts other seams, and labels paired cut edges.

For the multi-view workflow, use `複数視点から3D展開図を作成…` or `5視点から3D→展開図…`. It runs masked local photogrammetry, saves the USDZ, and immediately passes that USDZ to the mesh unfolder. The export button automatically switches to this route when three or more photos are loaded, so a multi-view project cannot silently produce the old two-face silhouette extrusion.

Extra photos are kept as references for the silhouette workflow. The old photo-only export remains a silhouette extrusion using the selected image. Automatic outlines now follow the detected mask boundary, while manually traced outlines provide the final correction path. The mesh pipeline is a first triangle-based unfolding prototype: it has a 2,500-face limit and does not simplify scans, preserve image textures, or yet optimize seams for visual quality. Non-planar meshes with very dense triangulation can therefore produce many small facets and require a separate mesh simplification step. Before selling a model, inspect the transparent preview, print the calibration bar, and verify a test assembly. All PDFs keep the requested width and tile larger layouts across A4 pages at 100% scale.
