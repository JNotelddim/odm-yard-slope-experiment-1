# Backyard Slope Photogrammetry — Attempt 1

**Status: failed.** The pipeline ran to completion three times and produced no usable
model or topographic map. The limiting factor was the photo capture, not the tooling.

Kept as a reference for the working commands, the environment gotchas, and what to do
differently on attempt 2.

> **Data removed (2026-09-10).** All photos and ODM outputs have been deleted — the
> photos carried GPS EXIF and the rasters, point cloud and mesh embedded UTM coordinates
> identifying the property. Only coordinate-free run metadata is kept: `options.json`
> (resolved parameter set), `benchmark.txt` (stage timings), `cameras.json` (intrinsics).
> Reproducing anything below starts with re-shooting — see the attempt-2 capture spec.

---

## Goal

Turn a handheld set of iPhone photos of a residential back slope (~14 x 17 m, rocky,
under near-continuous ivy and dry grass) into a 3D model and/or a topographic map with
contour lines.

Constraint: prefer a simple CLI that just ETLs the photos over learning a new GUI tool.

## Environment

| | |
|---|---|
| Machine | MacBook Pro, Apple M1 Max, 10 cores, 32 GB RAM |
| OS | macOS 26.6.2 |
| Photogrammetry | OpenDroneMap, `opendronemap/odm:latest` via Docker |
| Docker | Docker Desktop — **memory raised from 8 GB to 24 GB** (see Gotchas) |
| GDAL / PDAL | Bundled inside the ODM image (GDAL 3.11.1) |
| Viewer | QGIS.app |

`opendronemap/odm:latest` publishes a native `linux/arm64` manifest, so it runs natively
on Apple Silicon with no QEMU emulation. Verify with:

```bash
docker manifest inspect opendronemap/odm:latest | grep -A2 architecture
```

ODM's pipeline (OpenSfM + OpenMVS) is CPU-only — no CUDA anywhere. That is why it was
chosen over Meshroom and RealityScan, both of which require an NVIDIA GPU.

## Input

26 frames, iPhone 16, 5712 x 4284 (24.5 MP), focal 5.96 mm, HEIC with full EXIF
including GPS. Shot as an 83-second walkaround; GPS positions span roughly 14 x 17 m.

**Use the HEIC/JPEG originals, never PNG conversions.** PNG drops EXIF, and EXIF is what
gives the pipeline its camera intrinsics (focal length) plus a coarse georeference and
scale estimate. Feeding PNGs throws that away for no benefit.

## Pipeline

### 1. HEIC to JPEG, preserving EXIF

ODM reads JPEG/TIFF, not HEIC. `sips` is built into macOS and retains metadata.

```bash
mkdir -p ~/dev/casual-projects/slope/images
for f in ~/source-photos/*.HEIC; do
  sips -s format jpeg "$f" --out ~/dev/casual-projects/slope/images/"$(basename "${f%.HEIC}").jpg"
done

# Verify EXIF survived — if this prints nothing, stop and use exiftool instead
mdls -name kMDItemLatitude -name kMDItemFocalLength ~/dev/casual-projects/slope/images/*.jpg | head
```

### 2. Run ODM

Project layout matters: images must sit in `<project>/images/`, the project directory is
mounted at `/datasets/code`, and `--project-path` points at its parent.

```bash
docker run --rm -v ~/dev/casual-projects/slope:/datasets/code opendronemap/odm \
  --project-path /datasets \
  --feature-quality ultra \
  --min-num-features 20000 \
  --max-concurrency 6 \
  --pc-quality high \
  --use-3dmesh \
  --sky-removal \
  --auto-boundary \
  --dsm --dtm \
  --dem-resolution 3 \
  --pc-rectify \
  --rerun-all
```

See `run-odm.sh` for this as an executable script.

Flag rationale:

| Flag | Why |
|---|---|
| `--use-3dmesh` | Full 3D mesh instead of ODM's default 2.5D. Required for scenes that aren't flat and viewed from above. |
| `--sky-removal` | AI sky masking. **Essential here.** Unmasked sky pixels have no fixed depth and triangulate to arbitrary distances. |
| `--auto-boundary` | Limits reconstruction to the camera footprint. Without it, ODM reconstructs the entire background — neighbouring houses, trees 50–100 m out. |
| `--max-concurrency 6` | Caps worker threads. Default is your core count (10 here), which blows the memory budget. |
| `--rerun-all` | **Required when re-running with changed flags.** Otherwise ODM resumes from cached stages and silently keeps the previous bad reconstruction. |
| `--pc-rectify` | Reclassifies misclassified ground points and fills gaps. |
| `--dsm --dtm` | Neither is produced by default. |

### 3. Contours from the DSM

`gdal_contour` ships in the image but is **not on its `PATH`**. Use the full path:

```bash
docker run --rm -v ~/dev/casual-projects/slope:/data \
  --entrypoint /code/SuperBuild/install/bin/gdal_contour opendronemap/odm \
  -a elev -i 0.25 /data/odm_dem/dsm.tif /data/contours_25cm.gpkg
```

Not run in this attempt — there was never a DSM good enough to justify it.

## Results

Three runs. Docker memory was raised from 8 GB to 24 GB between run 1 and run 2.

| Metric | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Outcome | **OOM killed** (exit 137) | completed | completed |
| Registered frames | — | 16 / 26 | **15 / 26** |
| Avg track length | — | 2.043 | **2.043** |
| Sparse points | — | 16,093 | 19,367 |
| Dense points | — | — | 1,638,888 |
| DSM pixels below 0 m | — | 82.8% | **3.2%** |
| DSM in plausible band | — | 4.6% | 34.1% |
| Raster extent | — | 53 x 100 m | **21.6 x 26.9 m** |
| SfM time | — | ~157 s | ~235 s |

Run 3 added `--sky-removal` and `--auto-boundary`. Those two flags fixed the garbage
geometry — sub-zero pixels fell from 82.8% to 3.2% and the false extent collapsed.

**What they did not fix: registration stayed at 15–16 of 26, and average track length
stayed pinned at 2.04 across every configuration.**

### Why it failed

Track length 2.04 means the typical 3D point was triangulated from only **two** views —
the bare minimum, and the most error-prone case. Healthy photogrammetry runs 3–5+.

The camera network itself was roughly recovered (`components = 1`, bundle-adjusted
positions plausible when overlaid in QGIS). What failed was **per-pixel depth**: two-view
triangulation across wide baselines on low-texture, self-similar ivy leaves each point
pointing in roughly the right direction but at the wrong distance. That is the smearing
visible in the orthophoto and mesh.

Compounding it: the ivy and grass physically moved between frames. Every photogrammetry
pipeline assumes a rigid scene.

`dtm.tif` is separately broken — its median elevation sits ~15 m *below* the DSM's. SMRF
latched onto low-lying noise, classified it as ground, and dragged the terrain model down.
A bare-earth model cannot sit below the surface model on the same site. Do not use it.

### Also worth knowing

Under continuous groundcover, **no** photogrammetry tool — open source, commercial, or ML
— can recover bare-earth grade. The soil surface is not visible in any frame. A DSM will
capture the ivy canopy, roughly 10–40 cm above true grade and worse under shrubs. Cut the
vegetation back first if actual grade is the goal.

## Output file map

**These files no longer exist** (see the note at the top). Kept as a map of what a
successful run produces, all under the project root as siblings of `images/`:

| Path | What |
|---|---|
| `odm_orthophoto/odm_orthophoto.tif` | Orthophoto, RGBA (band 4 = alpha), EPSG:32610, 5 cm/px |
| `odm_dem/dsm.tif` | Digital Surface Model, 3 cm/px, nodata -9999 |
| `odm_dem/dtm.tif` | Digital Terrain Model — **broken, see above** |
| `odm_georeferencing/odm_georeferenced_model.laz` | Dense point cloud |
| `odm_texturing/odm_textured_model_geo.obj` | Textured 3D mesh |
| `odm_report/report.pdf` | Visual run summary, camera layout |
| `odm_report/stats.json` | Reconstruction statistics |
| `opensfm/` | Intermediate SfM data, ~788 MB, safe to delete |
| `log.json` | Full run log |

## Viewing in QGIS

Open `odm_orthophoto/odm_orthophoto.tif` first — CRS is embedded and band 4 is alpha, so
nodata renders transparent with no setup.

Add alongside:

- `odm_georeferencing/odm_georeferenced_model.laz` as a point cloud layer (QGIS 3.18+).
  The most honest view — measured points only, zero interpolation.
- `odm_report/shots.geojson` — registered camera positions (EPSG:4326, Z = altitude).
  These are bundle-adjusted poses, not raw GPS. Overlay to see coverage gaps directly.

**If opening `dsm.tif`, set the stretch manually** or it renders as a flat grey rectangle:
Layer Properties → Symbology → Min/Max. Auto-stretch gets dominated by outliers.

Useful context layer: Browser → XYZ Tiles → OpenStreetMap, dragged beneath the ortho.

## Verdict

Stop tuning flags. Three configurations, and the two numbers that matter never moved.
Eleven frames refused to register in both completed runs — all the elevated deck shots
and the entire eastern cluster. Flags can reject bad geometry, which they did well. They
cannot create views that were never captured.

### Attempt 2 capture spec

- **80–100 frames**, not 26
- **60–80% overlap** between consecutive frames
- **Two passes at different heights** along the slope, plus a dedicated set from above
  angled down. Every elevated shot dropped in attempt 1, and those are the views that
  constrain vertical structure.
- **Overcast day.** Hard shadows actively hurt feature matching.
- **Tape measure or known-length object in frame** for scale. Phone GPS altitude is
  unreliable — attempt 1 reported 12.3 m and 25 m within the same 83-second burst.
- Shoot **HEIC/JPEG straight off the phone**; skip any PNG step.

### Not attempted

- **VGGT / MASt3R feed-forward reconstruction.** These predict poses and dense depth from
  unposed images in a single pass, and published evaluation finds they beat COLMAP-style
  SfM specifically in the sparse-view, low-overlap regime — which is exactly where this
  attempt failed. Proposed as a ~15 min diagnostic to separate "photos salvageable" from
  "capture insufficient". Not run; out of time.
- **Contour generation.** No usable DSM to run it against.

Note on generative single-image-to-3D models (TRELLIS, Hunyuan3D, etc.): these are the
wrong tool for this. They hallucinate plausible geometry for a bounded object with no
metric scale. Useful for game assets, not for measuring terrain. The feed-forward
multi-view family above is the relevant ML approach.
