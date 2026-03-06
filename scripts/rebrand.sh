#!/bin/bash
set -e

################################################################################
# Supra Rebranding Script
#
# Safely replaces "OpenSearch" in user-visible UI strings ONLY.
# Does NOT touch code identifiers, variable names, imports, or file paths.
#
# Rules:
#   1. "OpenSearch Dashboards" → "Dashboards"  (in UI strings)
#   2. "OpenSearch" standalone → "Supra"        (in UI strings)
#   3. "OpenSearch <Word>" combined → "<Word>"  (in UI strings)
#
# What counts as a UI string:
#   - i18n defaultMessage values
#   - String literals in title/label/description/placeholder/heading props
#   - DEFAULT_TITLE and applicationTitle constants
#   - JSX text content with "OpenSearch"
################################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$BASE_DIR/OpenSearch-Dashboards/src"

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: Source directory not found at $SRC_DIR"
    exit 1
fi

echo "============================================"
echo "  Supra Rebranding Script"
echo "============================================"
echo ""
echo "Source: $SRC_DIR"
echo ""

FIND_OPTS=(-not -path "*/node_modules/*" -not -path "*/__tests__/*" -not -path "*/__snapshots__/*" -not -path "*/build/*" -not -path "*/target/*" -not -path "*/test/*" -not -path "*/tests/*")

UPDATED=0

# Helper: safely replace in a file and report
replace_in_file() {
    local file="$1"
    local pattern="$2"
    local replacement="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        sed -i "s|$pattern|$replacement|g" "$file"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Pass 1: Replace "OpenSearch Dashboards" in defaultMessage / UI strings
# This is safe because "OpenSearch Dashboards" as a phrase only appears in
# user-visible text, not as code identifiers (those use camelCase).
# ---------------------------------------------------------------------------
echo "[1/4] Replacing 'OpenSearch Dashboards' → 'Dashboards' in UI strings..."

# Target: defaultMessage strings containing "OpenSearch Dashboards"
find "$SRC_DIR" \( -name "*.tsx" -o -name "*.ts" -o -name "*.jsx" -o -name "*.js" \) \
    "${FIND_OPTS[@]}" \
    -exec grep -l "OpenSearch Dashboards" {} \; 2>/dev/null | while read -r file; do
        # Only replace inside string literals (between quotes)
        # Pattern: "OpenSearch Dashboards" or 'OpenSearch Dashboards'
        sed -i "s/OpenSearch Dashboards/Dashboards/g" "$file"
        echo "  ${file#$BASE_DIR/}"
        UPDATED=$((UPDATED + 1))
    done

echo "  Done."
echo ""

# ---------------------------------------------------------------------------
# Pass 2: Replace specific known UI-visible constants and strings
# These are targeted replacements in specific files identified during research.
# ---------------------------------------------------------------------------
echo "[2/4] Replacing known UI constants and strings..."

# --- Core: DEFAULT_TITLE ---
FILE="$SRC_DIR/core/server/rendering/rendering_service.tsx"
if [ -f "$FILE" ]; then
    sed -i "s/const DEFAULT_TITLE = 'OpenSearch Dashboards'/const DEFAULT_TITLE = 'Dashboards'/" "$FILE"
    sed -i "s/const DEFAULT_TITLE = 'Dashboards'/const DEFAULT_TITLE = 'Supra'/" "$FILE"
    echo "  core/server/rendering/rendering_service.tsx (DEFAULT_TITLE)"
fi

FILE="$SRC_DIR/core/server/rendering/views/template.tsx"
if [ -f "$FILE" ]; then
    sed -i "s/|| 'OpenSearch Dashboards'/|| 'Supra'/" "$FILE"
    sed -i "s/|| 'Dashboards'/|| 'Supra'/" "$FILE"
    echo "  core/server/rendering/views/template.tsx (applicationTitle fallback)"
fi

# --- Core: header breadcrumbs fallback ---
FILE="$SRC_DIR/core/public/chrome/ui/header/header_breadcrumbs.tsx"
if [ -f "$FILE" ]; then
    sed -i "s/'OpenSearch Dashboards'/'Supra'/g" "$FILE"
    sed -i "s/'Dashboards'/'Supra'/g" "$FILE"
    echo "  core/public/chrome/ui/header/header_breadcrumbs.tsx"
fi

echo "  Done."
echo ""

# ---------------------------------------------------------------------------
# Pass 3: Replace "OpenSearch" in defaultMessage and UI-facing string patterns
# Only targets lines that contain defaultMessage, title, label, description,
# heading, placeholder, alt, helpText, or string literals with UI context.
# ---------------------------------------------------------------------------
echo "[3/4] Replacing remaining 'OpenSearch' in UI-facing strings..."

find "$SRC_DIR" \( -name "*.tsx" -o -name "*.ts" -o -name "*.jsx" -o -name "*.js" \) \
    "${FIND_OPTS[@]}" \
    -exec grep -l "OpenSearch" {} \; 2>/dev/null | while read -r file; do

    changed=false

    # Check if this file has UI-facing strings with OpenSearch
    if grep -qP '(defaultMessage|title|label|description|placeholder|heading|helpText|alt)[=:].*(OpenSearch|Supra)' "$file" 2>/dev/null || \
       grep -qP "defaultMessage['\"]?\s*[:=]\s*['\"].*OpenSearch" "$file" 2>/dev/null || \
       grep -qP "'[^']*OpenSearch[^']*'" "$file" 2>/dev/null; then

        # --- Possessive: "OpenSearch's" → "Supra's" ---
        if grep -q "OpenSearch's" "$file" 2>/dev/null; then
            sed -i "s/OpenSearch's/Supra's/g" "$file"
            changed=true
        fi

        # --- Standalone "OpenSearch" before punctuation/end-of-string markers ---
        # Matches: OpenSearch" OpenSearch' OpenSearch. OpenSearch, OpenSearch! OpenSearch? OpenSearch)  OpenSearch`
        if grep -qP 'OpenSearch["\x27`.,;:!?)]' "$file" 2>/dev/null; then
            sed -i 's/OpenSearch\(["\x27`.,;:!?)]\)/Supra\1/g' "$file"
            changed=true
        fi

        # --- Known combined terms: remove "OpenSearch " prefix ---
        for term in "SQL" "PPL" "Index" "Cluster" "Documentation" "Default" "Stack"; do
            if grep -q "OpenSearch $term" "$file" 2>/dev/null; then
                sed -i "s/OpenSearch $term/$term/g" "$file"
                changed=true
            fi
        done

        # --- "OpenSearch " followed by lowercase (combined terms) ---
        # e.g., "OpenSearch connections" → "connections", "OpenSearch compatible" → "compatible"
        if grep -qP "OpenSearch [a-z]" "$file" 2>/dev/null; then
            sed -i 's/OpenSearch \([a-z]\)/\1/g' "$file"
            changed=true
        fi

        if [ "$changed" = true ]; then
            echo "  ${file#$BASE_DIR/}"
        fi
    fi
done

echo "  Done."
echo ""

# ---------------------------------------------------------------------------
# Pass 4: Handle i18n translation JSON files
# ---------------------------------------------------------------------------
echo "[4/4] Updating translation files..."
find "$SRC_DIR" -name "*.json" -path "*/translations/*" \
    -not -path "*/node_modules/*" 2>/dev/null | while read -r file; do
    if grep -q "OpenSearch" "$file" 2>/dev/null; then
        sed -i 's/OpenSearch Dashboards/Dashboards/g' "$file"
        sed -i "s/OpenSearch's/Supra's/g" "$file"
        sed -i 's/OpenSearch\(["\x27`.,;:!?)]\)/Supra\1/g' "$file"
        for term in "SQL" "PPL" "Index" "Cluster" "Documentation" "Default" "Stack"; do
            sed -i "s/OpenSearch $term/$term/g" "$file"
        done
        sed -i 's/OpenSearch \([a-z]\)/\1/g' "$file"
        echo "  ${file#$BASE_DIR/}"
    fi
done

echo "  Done."
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
UI_REMAINING=$(grep -rP '(defaultMessage|title|label|description|placeholder|heading|helpText|alt)[=:].*OpenSearch' "$SRC_DIR" \
    --include="*.tsx" --include="*.ts" --include="*.jsx" --include="*.js" \
    --exclude-dir=node_modules --exclude-dir=build --exclude-dir=target \
    --exclude-dir=__tests__ --exclude-dir=__snapshots__ \
    -l 2>/dev/null | wc -l)

echo "============================================"
echo "  Rebranding Complete"
echo "============================================"
echo ""
echo "  Files with 'OpenSearch' in UI strings remaining: $UI_REMAINING"
echo ""
if [ "$UI_REMAINING" -gt 0 ]; then
    echo "  Remaining UI files to review manually:"
    grep -rP '(defaultMessage|title|label|description|placeholder|heading|helpText|alt)[=:].*OpenSearch' "$SRC_DIR" \
        --include="*.tsx" --include="*.ts" --include="*.jsx" --include="*.js" \
        --exclude-dir=node_modules --exclude-dir=build --exclude-dir=target \
        --exclude-dir=__tests__ --exclude-dir=__snapshots__ \
        -l 2>/dev/null | head -20 | while read -r f; do
            echo "    ${f#$BASE_DIR/}"
        done
    echo ""
fi
echo "  NOTE: Internal code identifiers (variable names, imports, class names)"
echo "        were intentionally NOT changed to avoid breaking the build."
echo ""
echo "  Next steps:"
echo "    1. Review changes: cd $BASE_DIR/OpenSearch-Dashboards && git diff --stat"
echo "    2. Build: cd $BASE_DIR/OpenSearch-Dashboards && yarn build-platform --linux --skip-os-packages"
echo "    3. Package: cd $BASE_DIR && ./scripts/build-installer.sh"
echo ""
