#!/usr/bin/env bash
# Backyard slope photogrammetry — OpenDroneMap run.
# See README.md for flag rationale, results, and known gotchas.
set -euo pipefail

PROJECT="${PROJECT:-$HOME/slope}"
SOURCE_PHOTOS="${SOURCE_PHOTOS:-}"

# --- Step 1 (optional): HEIC -> JPEG, preserving EXIF -------------------------
# Set SOURCE_PHOTOS to a folder of .HEIC originals to (re)build the image set.
# EXIF matters: focal length gives camera intrinsics, GPS gives coarse scale.
if [[ -n "$SOURCE_PHOTOS" ]]; then
  echo "Converting HEIC -> JPEG from $SOURCE_PHOTOS ..."
  mkdir -p "$PROJECT/images"
  for f in "$SOURCE_PHOTOS"/*.HEIC; do
    [[ -e "$f" ]] || { echo "No .HEIC files found in $SOURCE_PHOTOS"; exit 1; }
    sips -s format jpeg "$f" --out "$PROJECT/images/$(basename "${f%.HEIC}").jpg" >/dev/null
  done
  echo "Converted $(ls -1 "$PROJECT"/images/*.jpg | wc -l | tr -d ' ') images."
  echo "EXIF spot-check:"
  mdls -name kMDItemLatitude -name kMDItemFocalLength "$PROJECT"/images/*.jpg | head -4
fi

# --- Step 2: run the pipeline -------------------------------------------------
# Requires Docker Desktop memory >= 24 GB. At 8 GB this is OOM-killed (exit 137)
# with no error message. ODM's own budget: ~1 GB per thread at 2 MP, so ~12 GB
# per thread at 24.5 MP.
echo "Running ODM (expect ~20 min on an M1 Max for ~26 x 24 MP frames)..."
docker run --rm -v "$PROJECT":/datasets/code opendronemap/odm \
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

# --- Step 3: sanity-check the result before trusting it -----------------------
# Registration count and average track length are the two numbers that matter.
# Track length below ~2.5 means mostly two-view triangulation = unreliable depth.
echo
echo "=== reconstruction stats ==="
python3 - "$PROJECT" <<'PYEOF'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(f"{p}/opensfm/stats/stats.json"))
except FileNotFoundError:
    sys.exit("no stats.json — the run did not reach reconstruction")
r = d.get("reconstruction_statistics", {})
for k in ("initial_shots_count", "reconstructed_shots_count",
          "average_track_length", "reconstructed_points_count", "components"):
    if k in r:
        print(f"  {k} = {r[k]}")
PYEOF

# --- Step 4 (optional): contours from the DSM ---------------------------------
# gdal_contour ships in the image but is NOT on its PATH.
#
# docker run --rm -v "$PROJECT":/data \
#   --entrypoint /code/SuperBuild/install/bin/gdal_contour opendronemap/odm \
#   -a elev -i 0.25 /data/odm_dem/dsm.tif /data/contours_25cm.gpkg
