#!/bin/bash
# ============================================================
# import-instagram.sh
#
# Imports an Instagram data export into mygram format.
#
# Reads posts_1.json from an Instagram export folder, copies
# media files, generates web-optimized images + thumbnails,
# and builds/merges entries into data/photos.json.
#
# Handles:
#   - Single-photo posts
#   - Multi-photo carousel posts (media array)
#   - Video posts (mp4) — requires ffmpeg
#   - Captions (Instagram's UTF-8-as-Latin-1 mojibake is
#     preserved as-is; fix manually if needed)
#   - EXIF extraction from original images
#   - GPS reverse-geocoding
#
# Requirements:
#   brew install exiftool imagemagick jq
#   brew install ffmpeg   (optional, for video)
#
# Usage:
#   ./scripts/import-instagram.sh "path/to/instagram export"
#   ./scripts/import-instagram.sh   # defaults to "instagram export" in project root
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ---- Instagram export path ----
EXPORT_DIR="${1:-$PROJECT_DIR/instagram export}"
POSTS_JSON="$EXPORT_DIR/posts_1.json"

if [[ ! -f "$POSTS_JSON" ]]; then
  echo "❌  Cannot find $POSTS_JSON"
  echo "Usage: $0 [path/to/instagram-export-folder]"
  exit 1
fi

echo "📦  Instagram export: $EXPORT_DIR"
echo "📄  Posts JSON: $POSTS_JSON"

# ---- Paths ----
THUMBS_DIR="$PROJECT_DIR/photos/thumbnails"
THUMBS_640_DIR="$PROJECT_DIR/photos/thumbnails/640"
THUMBS_360_DIR="$PROJECT_DIR/photos/thumbnails/360"
WEB_DIR="$PROJECT_DIR/photos/web"
JSON_FILE="$PROJECT_DIR/data/photos.json"
THUMB_SIZE="1080x1080"
THUMB_640_SIZE="640x640"
THUMB_360_SIZE="360x360"
WEB_QUALITY="70"
THUMB_QUALITY="75"
WEB_MAX_DIMENSION="2048"

SUPPORTED_EXTENSIONS="jpg|jpeg|png|tiff|tif|heic|heif|webp|avif|bmp"
VIDEO_EXTENSIONS="mp4|mov|avi|mkv|webm|m4v"

# ---- Check dependencies ----
missing=()
command -v exiftool >/dev/null 2>&1 || missing+=("exiftool")
command -v jq       >/dev/null 2>&1 || missing+=("jq")
if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
  missing+=("imagemagick")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "❌  Missing dependencies: ${missing[*]}"
  echo "   Install with:  brew install ${missing[*]}"
  exit 1
fi

if command -v magick >/dev/null 2>&1; then
  MAGICK_CMD="magick"
else
  MAGICK_CMD="convert"
fi

HAS_FFMPEG=false
command -v ffmpeg >/dev/null 2>&1 && HAS_FFMPEG=true

# ---- Ensure directories ----
mkdir -p "$THUMBS_DIR" "$THUMBS_640_DIR" "$THUMBS_360_DIR" "$WEB_DIR"

# ---- Ensure JSON file exists ----
if [[ ! -f "$JSON_FILE" ]]; then
  echo '{"profile":{},"photos":[],"albums":[]}' | jq . > "$JSON_FILE"
fi

# ---- Migrate old-format entries if needed ----
needs_migration=$(jq '[.photos[] | select(.media == null)] | length' "$JSON_FILE" 2>/dev/null || echo "0")
if [[ "$needs_migration" -gt 0 ]]; then
  echo "🔄  Migrating $needs_migration existing entry/entries to new media format..."
  tmp=$(mktemp)
  jq '.photos = [.photos[] |
    if .media == null then
      . + { media: [{ type: "image", web: .web, thumbnail: .thumbnail }] }
    else . end
  ]' "$JSON_FILE" > "$tmp"
  mv "$tmp" "$JSON_FILE"
fi

# ---- Collect already-known slugs to avoid duplicates ----
known_slugs=$(jq -r '.photos[].slug // empty' "$JSON_FILE" 2>/dev/null || echo "")

total_posts=$(jq 'length' "$POSTS_JSON")
echo ""
echo "📸  Found $total_posts posts in Instagram export"
echo ""

new_count=0
skipped_count=0
error_count=0

# ---- Process each Instagram post ----
# We iterate by index so we can extract each post with jq
for (( idx=0; idx<total_posts; idx++ )); do
  # Extract post data
  post_json=$(jq ".[$idx]" "$POSTS_JSON")

  # Post-level caption (Instagram calls it "title")
  caption=$(echo "$post_json" | jq -r '.title // empty' 2>/dev/null || echo "")

  # Also fall back to caption on the first media item (Instagram sometimes puts it there)
  if [[ -z "$caption" ]]; then
    caption=$(echo "$post_json" | jq -r '.media[0].title // empty' 2>/dev/null || echo "")
  fi

  # Post creation timestamp → ISO date
  creation_ts=$(echo "$post_json" | jq -r '.creation_timestamp // empty' 2>/dev/null || echo "")
  post_date=""
  if [[ -n "$creation_ts" && "$creation_ts" != "0" ]]; then
    post_date=$(date -r "$creation_ts" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
  fi
  # Fallback: try the first media item's timestamp
  if [[ -z "$post_date" ]]; then
    media_ts=$(echo "$post_json" | jq -r '.media[0].creation_timestamp // empty' 2>/dev/null || echo "")
    if [[ -n "$media_ts" && "$media_ts" != "0" ]]; then
      post_date=$(date -r "$media_ts" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "")
      creation_ts="$media_ts"
    fi
  fi

  # Number of media items in this post
  media_count=$(echo "$post_json" | jq '.media | length')

  # Generate a slug from the timestamp + index
  if [[ -n "$creation_ts" ]]; then
    base_slug="ig-${creation_ts}"
  else
    base_slug="ig-post-${idx}"
  fi
  slug=$(echo "$base_slug" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

  # Skip if already imported
  if echo "$known_slugs" | grep -qxF "$slug"; then
    skipped_count=$((skipped_count + 1))
    continue
  fi

  progress="[$((idx + 1))/$total_posts]"
  echo "→ $progress Processing post from $(echo "$post_date" | cut -c1-10) ($media_count media item(s))"

  # ---- Process each media item ----
  media_array_json="[]"
  first_web=""
  first_thumb=""
  post_camera=""
  post_lens=""
  post_settings=""
  post_location=""
  post_gps_lat=""
  post_gps_lon=""
  post_width=""
  post_height=""
  any_error=false

  for (( mi=0; mi<media_count; mi++ )); do
    item_json=$(echo "$post_json" | jq ".media[$mi]")
    uri=$(echo "$item_json" | jq -r '.uri // empty')

    if [[ -z "$uri" ]]; then
      echo "   ⚠ Media item $mi has no URI, skipping"
      continue
    fi

    # Resolve full path to the media file
    src_file="$EXPORT_DIR/$uri"

    if [[ ! -f "$src_file" ]]; then
      echo "   ⚠ File not found: $uri"
      any_error=true
      continue
    fi

    src_filename="$(basename "$src_file")"
    src_ext="${src_filename##*.}"
    src_ext_lower=$(echo "$src_ext" | tr '[:upper:]' '[:lower:]')

    # Determine if video or image
    item_is_video=false
    if echo "$src_ext_lower" | grep -qE "^($VIDEO_EXTENSIONS)$"; then
      item_is_video=true
    elif ! echo "$src_ext_lower" | grep -qE "^($SUPPORTED_EXTENSIONS)$"; then
      echo "   ⚠ Unsupported file type: $src_filename"
      continue
    fi

    # Build unique output filenames using slug + media index
    if [[ $media_count -gt 1 ]]; then
      out_base="${slug}-$((mi + 1))"
    else
      out_base="${slug}"
    fi

    if $item_is_video; then
      if ! $HAS_FFMPEG; then
        echo "   ⚠ Skipping video (ffmpeg not installed): $src_filename"
        continue
      fi

      v_web="${out_base}.mp4"
      v_poster="${out_base}-poster.webp"
      v_thumb="thumb_${out_base}.webp"

      # Encode to web-optimized MP4
      if ! ffmpeg -y -i "$src_file" \
        -c:v libx264 -crf 23 -preset medium \
        -c:a aac -b:a 128k \
        -movflags +faststart \
        -vf "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease" \
        "$WEB_DIR/$v_web" 2>/dev/null; then
        echo "   ⚠ Failed to encode video: $src_filename, skipping"
        rm -f "$WEB_DIR/$v_web"
        continue
      fi

      # Extract poster frame
      if ! ffmpeg -y -i "$src_file" -vframes 1 -ss 00:00:01 \
        -vf "scale='min(2048,iw)':'min(2048,ih)':force_original_aspect_ratio=decrease" \
        "$WEB_DIR/$v_poster" 2>/dev/null; then
        ffmpeg -y -i "$src_file" -vframes 1 \
          "$WEB_DIR/$v_poster" 2>/dev/null || {
          echo "   ⚠ Failed to extract poster frame: $src_filename, skipping"
          rm -f "$WEB_DIR/$v_web" "$WEB_DIR/$v_poster"
          continue
        }
      fi

      # Thumbnails from poster
      if ! $MAGICK_CMD "$WEB_DIR/$v_poster" -auto-orient \
        -thumbnail "${THUMB_SIZE}^" -gravity center -extent "$THUMB_SIZE" \
        -quality "$THUMB_QUALITY" "$THUMBS_DIR/$v_thumb" 2>/dev/null; then
        echo "   ⚠ Failed to generate thumbnails for video: $src_filename, skipping"
        continue
      fi
      $MAGICK_CMD "$WEB_DIR/$v_poster" -auto-orient \
        -thumbnail "${THUMB_640_SIZE}^" -gravity center -extent "$THUMB_640_SIZE" \
        -quality "$THUMB_QUALITY" "$THUMBS_640_DIR/$v_thumb" 2>/dev/null || true
      $MAGICK_CMD "$WEB_DIR/$v_poster" -auto-orient \
        -thumbnail "${THUMB_360_SIZE}^" -gravity center -extent "$THUMB_360_SIZE" \
        -quality "$THUMB_QUALITY" "$THUMBS_360_DIR/$v_thumb" 2>/dev/null || true

      # Duration
      dur=$(ffprobe -v quiet -print_format json -show_entries format=duration \
        "$src_file" 2>/dev/null | jq -r '.format.duration // empty' 2>/dev/null || echo "")
      dur_str=""
      if [[ -n "$dur" ]]; then
        di=${dur%.*}
        dur_str=$(printf "%d:%02d" "$((di / 60))" "$((di % 60))" 2>/dev/null || echo "")
      fi

      media_array_json=$(echo "$media_array_json" | jq \
        --arg w "$v_web" --arg p "$v_poster" --arg t "$v_thumb" --arg d "$dur_str" \
        '. + [{ type: "video", web: $w, poster: $p, thumbnail: $t, duration: $d }]')

      if [[ -z "$first_web" ]]; then
        first_web="$v_poster"
        first_thumb="$v_thumb"
      fi

      echo "   ✓ Video [$((mi + 1))/$media_count] → $v_web"

    else
      # ---- Image processing ----
      i_web="${out_base}.webp"
      i_thumb="thumb_${out_base}.webp"

      # Web-optimized WebP
      if ! $MAGICK_CMD "$src_file" -auto-orient \
        -resize "${WEB_MAX_DIMENSION}x${WEB_MAX_DIMENSION}>" \
        -quality "$WEB_QUALITY" \
        "$WEB_DIR/$i_web" 2>/dev/null; then
        echo "   ⚠ Failed to convert image: $src_filename, skipping"
        continue
      fi

      # Thumbnails (1080 / 640 / 360)
      $MAGICK_CMD "$src_file" -auto-orient \
        -thumbnail "${THUMB_SIZE}^" -gravity center -extent "$THUMB_SIZE" \
        -quality "$THUMB_QUALITY" "$THUMBS_DIR/$i_thumb" 2>/dev/null || true
      $MAGICK_CMD "$src_file" -auto-orient \
        -thumbnail "${THUMB_640_SIZE}^" -gravity center -extent "$THUMB_640_SIZE" \
        -quality "$THUMB_QUALITY" "$THUMBS_640_DIR/$i_thumb" 2>/dev/null || true
      $MAGICK_CMD "$src_file" -auto-orient \
        -thumbnail "${THUMB_360_SIZE}^" -gravity center -extent "$THUMB_360_SIZE" \
        -quality "$THUMB_QUALITY" "$THUMBS_360_DIR/$i_thumb" 2>/dev/null || true

      media_array_json=$(echo "$media_array_json" | jq \
        --arg w "$i_web" --arg t "$i_thumb" \
        '. + [{ type: "image", web: $w, thumbnail: $t }]')

      if [[ -z "$first_web" ]]; then
        first_web="$i_web"
        first_thumb="$i_thumb"
      fi

      # Extract EXIF from first image for post-level metadata
      if [[ $mi -eq 0 ]]; then
        exif_json=$(exiftool -json -d "%Y-%m-%dT%H:%M:%S" \
          -DateTimeOriginal -CreateDate -ModifyDate \
          -Make -Model -LensModel \
          -FocalLength -FNumber -ExposureTime -ISO \
          -GPSLatitude -GPSLongitude \
          -ImageWidth -ImageHeight \
          "$src_file" 2>/dev/null || echo "[{}]")

        make_v=$(echo "$exif_json" | jq -r '.[0].Make // empty' 2>/dev/null || echo "")
        model_v=$(echo "$exif_json" | jq -r '.[0].Model // empty' 2>/dev/null || echo "")
        post_lens=$(echo "$exif_json" | jq -r '.[0].LensModel // empty' 2>/dev/null || echo "")
        focal_v=$(echo "$exif_json" | jq -r '.[0].FocalLength // empty' 2>/dev/null || echo "")
        aperture_v=$(echo "$exif_json" | jq -r '.[0].FNumber // empty' 2>/dev/null || echo "")
        shutter_v=$(echo "$exif_json" | jq -r '.[0].ExposureTime // empty' 2>/dev/null || echo "")
        iso_v=$(echo "$exif_json" | jq -r '.[0].ISO // empty' 2>/dev/null || echo "")
        post_gps_lat=$(echo "$exif_json" | jq -r '.[0].GPSLatitude // empty' 2>/dev/null || echo "")
        post_gps_lon=$(echo "$exif_json" | jq -r '.[0].GPSLongitude // empty' 2>/dev/null || echo "")
        post_width=$(echo "$exif_json" | jq -r '.[0].ImageWidth // empty' 2>/dev/null || echo "")
        post_height=$(echo "$exif_json" | jq -r '.[0].ImageHeight // empty' 2>/dev/null || echo "")

        # Camera string
        if [[ -n "$make_v" && -n "$model_v" ]]; then
          if echo "$model_v" | grep -qi "$make_v"; then
            post_camera="$model_v"
          else
            post_camera="$make_v $model_v"
          fi
        elif [[ -n "$model_v" ]]; then
          post_camera="$model_v"
        fi

        # Settings string
        sp=()
        [[ -n "$focal_v" ]] && sp+=("$focal_v")
        [[ -n "$aperture_v" ]] && sp+=("f/$aperture_v")
        [[ -n "$shutter_v" ]] && sp+=("${shutter_v}s")
        [[ -n "$iso_v" ]] && sp+=("ISO $iso_v")
        if [[ ${#sp[@]} -gt 0 ]]; then
          post_settings=$(IFS="  "; echo "${sp[*]}")
        fi

        # Reverse-geocode GPS
        if [[ -n "$post_gps_lat" && -n "$post_gps_lon" ]]; then
          post_location=$(curl -sf \
            -H "User-Agent: mygram-photo-site/1.0" \
            "https://nominatim.openstreetmap.org/reverse?lat=${post_gps_lat}&lon=${post_gps_lon}&format=json&zoom=10" \
            | jq -r '.display_name // empty' 2>/dev/null || echo "")
          if [[ -n "$post_location" ]]; then
            post_location=$(echo "$post_location" | cut -d',' -f1-2 | sed 's/^ *//;s/ *$//')
          fi
          sleep 1  # be polite to Nominatim
        fi
      fi

      echo "   ✓ Image [$((mi + 1))/$media_count] → $i_web"
    fi
  done

  # Skip post if no media items were processed
  actual_media_count=$(echo "$media_array_json" | jq 'length')
  if [[ "$actual_media_count" -eq 0 ]]; then
    echo "   ⚠ No media items processed, skipping post"
    error_count=$((error_count + 1))
    continue
  fi

  # Use the original Instagram filename as the filename field
  first_uri=$(echo "$post_json" | jq -r '.media[0].uri // empty')
  ig_filename="$(basename "$first_uri")"

  # ---- Build mygram JSON entry ----
  new_entry=$(jq -n \
    --arg fn "$ig_filename" \
    --arg wf "$first_web" \
    --arg th "$first_thumb" \
    --arg sl "$slug" \
    --arg dt "$post_date" \
    --arg cap "$caption" \
    --arg cam "$post_camera" \
    --arg ln "$post_lens" \
    --arg st "$post_settings" \
    --arg loc "$post_location" \
    --arg lat "$post_gps_lat" \
    --arg lon "$post_gps_lon" \
    --arg w "$post_width" \
    --arg h "$post_height" \
    --argjson media "$media_array_json" \
    '{
      filename: $fn,
      web: $wf,
      thumbnail: $th,
      slug: $sl,
      date: $dt,
      caption: $cap,
      camera: $cam,
      lens: $ln,
      settings: $st,
      location: $loc,
      gps: { lat: $lat, lon: $lon },
      width: ($w | if . != "" then tonumber else null end),
      height: ($h | if . != "" then tonumber else null end),
      media: $media
    }')

  # Append to photos array
  tmp=$(mktemp)
  jq --argjson entry "$new_entry" '.photos = .photos + [$entry]' "$JSON_FILE" > "$tmp"
  mv "$tmp" "$JSON_FILE"

  new_count=$((new_count + 1))

  if $any_error; then
    error_count=$((error_count + 1))
  fi
done

# ---- Sort photos newest-first by date ----
if [[ $new_count -gt 0 ]]; then
  tmp=$(mktemp)
  jq '.photos |= sort_by(.date) | .photos |= reverse' "$JSON_FILE" > "$tmp"
  mv "$tmp" "$JSON_FILE"
  echo ""
  echo "📅  Sorted photos newest-first by date."
fi

# ---- Update post count ----
total_in_json=$(jq '.photos | length' "$JSON_FILE")

echo ""
echo "============================================"
echo "✅  Import complete!"
echo "   Imported: $new_count post(s)"
echo "   Skipped:  $skipped_count (already imported)"
echo "   Errors:   $error_count"
echo "   Total in photos.json: $total_in_json"
echo "============================================"

if [[ $new_count -gt 0 ]]; then
  # Generate sitemap if siteUrl is set
  SITEMAP_FILE="$PROJECT_DIR/sitemap.xml"
  SITE_URL=$(jq -r '.profile.siteUrl // empty' "$JSON_FILE")
  if [[ -n "$SITE_URL" ]]; then
    {
      echo '<?xml version="1.0" encoding="UTF-8"?>'
      echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
      echo "  <url><loc>${SITE_URL}</loc></url>"
      jq -r --arg base "$SITE_URL" '.photos[].slug | "  <url><loc>\($base)#photo=\(.)</loc></url>"' "$JSON_FILE"
      echo '</urlset>'
    } > "$SITEMAP_FILE"
    echo "🗺  Generated sitemap.xml"
  fi
fi
