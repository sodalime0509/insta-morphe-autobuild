#!/usr/bin/env bash
# dl_uptodown.sh — Download Instagram APK from Uptodown
#
# Usage: ./dl_uptodown.sh <version|latest> <output_file>

set -euo pipefail

# Allow passing --version-only to just print the detected version
if [ "${1:-}" = "--version-only" ]; then
    curl -s -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0" \
        "https://instagram.en.uptodown.com/android/versions" \
        | grep -oP '(?<=<span class="version">)[^<]+' \
        | head -1 | tr -d ' \n\r'
    exit 0
fi

VERSION="${1:?Usage: $0 <version|latest> <output_file>}"
OUTPUT="${2:?Usage: $0 <version|latest> <output_file>}"

UPTODOWN_BASE="https://instagram.en.uptodown.com/android"
UA="Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0"
COOKIE="$(mktemp /tmp/utd-XXXXXX.txt)"

# Clean up cookie file on exit
trap 'rm -f "$COOKIE"' EXIT

req() {
    curl -L \
        -c "$COOKIE" -b "$COOKIE" \
        --connect-timeout 15 --retry 3 --retry-delay 5 \
        --fail -s -S \
        -H "User-Agent: $UA" \
        "$@"
}

echo "=== Uptodown Instagram Downloader ==="

# Step 1: Get latest version if needed
if [ "$VERSION" = "latest" ]; then
    echo "Fetching latest version..."
    VERSION_PAGE=$(req "$UPTODOWN_BASE/versions")
    VERSION=$(grep -oP '<span class="version">\K[^<]+' <<< "$VERSION_PAGE" \
        | head -1 \
        | tr -d ' \n\r')
    [ -z "$VERSION" ] && { echo "ERROR: Could not detect latest version"; exit 1; }
    echo "Latest version: $VERSION"
fi
echo "Target: $VERSION"

# Step 2: Get app data-code
echo "Getting app data-code..."
DL_PAGE=$(req "$UPTODOWN_BASE/download")
DATA_CODE=$(grep -oP 'id="detail-app-name"[^>]*data-code="\K[^"]+' <<< "$DL_PAGE" | head -1 || true)
[ -z "$DATA_CODE" ] && { echo "ERROR: Could not get data-code"; exit 1; }
echo "data-code: $DATA_CODE"

# Step 3: Find version in paginated list
echo "Searching for version..."
VERSION_URL=""
for PAGE in $(seq 1 20); do
    RESP=$(req "${UPTODOWN_BASE}/apps/${DATA_CODE}/versions/${PAGE}")
    VERSION_URL=$(echo "$RESP" | jq -r --arg v "$VERSION" '
        .data[]?
        | select(.version == $v)
        | .versionURL
        | if . then (.url + "/" + .extraURL + "/" + (.versionID | tostring)) else empty end
    ' 2>/dev/null | head -1 || true)
    [ -n "$VERSION_URL" ] && { echo "Found on page $PAGE"; break; }
    HAS=$(echo "$RESP" | jq -r '.data | length' 2>/dev/null || echo "0")
    [ "$HAS" = "0" ] || [ "$HAS" = "null" ] && break
done

[ -z "$VERSION_URL" ] && { echo "ERROR: Version $VERSION not found"; exit 1; }
echo "Version URL: $VERSION_URL"

# Step 4: Get the version page and extract download URL
echo "Getting download page..."
VER_PAGE=$(req "$VERSION_URL")

# Flatten the HTML to handle multi-line tags (which break standard line-by-line grep)
FLAT_HTML=$(tr -d '\n\r' <<< "$VER_PAGE")
DIRECT_URL=""

# 1. Find the exact button tag, regardless of how many lines it spans
BUTTON_TAG=$(grep -oP '<[^>]*id="detail-download-button"[^>]*>' <<< "$FLAT_HTML" | head -1 || true)

if [ -n "$BUTTON_TAG" ]; then
    # Extract data-url or href from within the exact button tag
    DIRECT_URL=$(grep -oP 'data-url="\K[^"]+' <<< "$BUTTON_TAG" | head -1 || true)
    if [ -z "$DIRECT_URL" ]; then
        DIRECT_URL=$(grep -oP 'href="\K[^"]+' <<< "$BUTTON_TAG" | head -1 || true)
    fi
fi

# 2. Fallback: Search for dw.uptodown.com link inside ANY data-url
if [ -z "$DIRECT_URL" ]; then
    DIRECT_URL=$(grep -oP 'data-url="\K(?:https?:)?//dw\.uptodown\.com[^"]*' <<< "$FLAT_HTML" | head -1 || true)
fi

# 3. Fallback: Look for the first full direct download link in the page
if [ -z "$DIRECT_URL" ]; then
    DIRECT_URL=$(grep -oP 'https://dw\.uptodown\.com/dwn/[^"'\''>< ]+' <<< "$FLAT_HTML" | head -1 || true)
fi

# 4. Fallback: Try downloading via the main URL directly with octet-stream header
if [ -z "$DIRECT_URL" ]; then
    VERSION_ID=$(grep -oP '[0-9]+$' <<< "$VERSION_URL" || true)
    if [ -n "$VERSION_ID" ]; then
        echo "Trying direct download endpoint for version ID: $VERSION_ID"
        req -L "$VERSION_URL" -H "Accept: application/octet-stream" -o "$OUTPUT" || true
        # Check if we got a valid file > 1MB
        if [ -f "$OUTPUT" ] && [ "$(wc -c < "$OUTPUT" 2>/dev/null | tr -d ' ' || echo 0)" -gt 1000000 ]; then
            MAGIC=$(xxd -p -l 2 "$OUTPUT")
            if [ "$MAGIC" = "504b" ]; then
                SIZE=$(du -sh "$OUTPUT" | cut -f1)
                echo "Done: $OUTPUT ($SIZE)"
                echo "APK verified ✓"
                exit 0
            fi
        fi
        rm -f "$OUTPUT" # Clean up if invalid file
    fi
fi

if [ -z "$DIRECT_URL" ]; then
    echo "ERROR: Could not extract download URL from version page: $VERSION_URL"
    exit 1
fi

# Normalize the URL so curl handles it properly
if [[ "$DIRECT_URL" == //* ]]; then
    DIRECT_URL="https:$DIRECT_URL"
elif [[ "$DIRECT_URL" == /* ]]; then
    DIRECT_URL="https://dw.uptodown.com$DIRECT_URL"
elif [[ "$DIRECT_URL" != http* ]]; then
    DIRECT_URL="https://dw.uptodown.com/dwn/$DIRECT_URL"
fi

echo "Downloading: $DIRECT_URL"
req "$DIRECT_URL" -o "$OUTPUT"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
echo "Done: $OUTPUT ($SIZE)"

# Verify APK magic number
MAGIC=$(xxd -p -l 2 "$OUTPUT")
[ "$MAGIC" != "504b" ] && { echo "ERROR: Not a valid APK/XAPK (magic=$MAGIC)"; rm -f "$OUTPUT"; exit 1; }
echo "APK verified ✓"
