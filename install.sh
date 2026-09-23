#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PTERODACTYL AUTO NEST + EGG IMPORT
# Synced with the Axyluz installer flow:
# - Find or create Nest
# - Import a PTDL_v2 Egg through:
#   POST /api/application/nests/{nest}/import
# - Multipart field fallback: file -> import_file
# ============================================================

# GitHub repository containing this script and the Egg.
# Change USERNAME/REPOSITORY once before uploading to GitHub.
GITHUB_RAW_BASE="${GITHUB_RAW_BASE:-https://raw.githubusercontent.com/USERNAME/REPOSITORY/main}"
EGG_FILE="${EGG_FILE:-eggs/RizzXautoeggs.json}"

API_ACCEPT="Application/vnd.pterodactyl.v1+json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

die() {
    error "$*"
    exit 1
}

# ------------------------------------------------------------
# Requirements
# ------------------------------------------------------------

command -v curl >/dev/null 2>&1 || die "curl belum terinstall."
command -v jq   >/dev/null 2>&1 || die "jq belum terinstall. Install: apt install -y jq"

# ------------------------------------------------------------
# Input
# ------------------------------------------------------------

clear
echo "=========================================="
echo "      PTERODACTYL AUTO NEST + EGG"
echo "=========================================="
echo

read -rp "Panel URL: " PANEL_URL
read -rsp "Application API Key (ptla_...): " API_KEY
echo
read -rp "Nest Name [AUTONESTBYAXYLUZ]: " NEST_NAME
read -rp "Nest Description [Nest dibuat otomatis oleh Axyluz Installer]: " NEST_DESCRIPTION

PANEL_URL="${PANEL_URL%/}"
NEST_NAME="${NEST_NAME:-AUTONESTBYAXYLUZ}"
NEST_DESCRIPTION="${NEST_DESCRIPTION:-Nest dibuat otomatis oleh Axyluz Installer}"

[[ "$API_KEY" =~ ^ptla_[A-Za-z0-9_-]+$ ]] || \
    die "API key harus berupa Application API Key (ptla_...)."

# ------------------------------------------------------------
# Generic JSON API request
# ------------------------------------------------------------

api_json() {
    local method="$1"
    local endpoint="$2"
    local body="${3:-}"

    local args=(
        -sS
        -X "$method"
        "${PANEL_URL}/api/application${endpoint}"
        -H "Authorization: Bearer ${API_KEY}"
        -H "Accept: ${API_ACCEPT}"
        -H "User-Agent: Axyluz-AutoNest/1.0"
    )

    if [[ -n "$body" ]]; then
        args+=(
            -H "Content-Type: application/json"
            --data "$body"
        )
    fi

    curl "${args[@]}"
}

# ------------------------------------------------------------
# Test API
# ------------------------------------------------------------

info "Menguji Application API..."

NESTS_RESPONSE="$(api_json GET "/nests?per_page=100" 2>/dev/null || true)"

echo "$NESTS_RESPONSE" | jq -e '.object == "list"' >/dev/null 2>&1 || {
    error "Application API tidak dapat digunakan."
    echo
    echo "$NESTS_RESPONSE" | jq . 2>/dev/null || echo "$NESTS_RESPONSE"
    exit 1
}

success "Application API terhubung."

# ------------------------------------------------------------
# Find or create Nest
# ------------------------------------------------------------

info "Mencari Nest: $NEST_NAME"

NEST_ID="$(
    echo "$NESTS_RESPONSE" |
    jq -r --arg name "$NEST_NAME" '
        .data[]
        | select((.attributes.name // "") | ascii_downcase == ($name | ascii_downcase))
        | .attributes.id
    ' | head -n1
)"

if [[ -n "$NEST_ID" && "$NEST_ID" != "null" ]]; then
    success "Nest sudah ada. ID: $NEST_ID"
else
    info "Nest belum ada. Membuat Nest..."

    NEST_PAYLOAD="$(
        jq -n \
            --arg name "$NEST_NAME" \
            --arg description "$NEST_DESCRIPTION" \
            '{
                name: $name,
                description: $description
            }'
    )"

    CREATE_RESPONSE="$(api_json POST "/nests" "$NEST_PAYLOAD")"

    NEST_ID="$(
        echo "$CREATE_RESPONSE" |
        jq -r '.attributes.id // empty'
    )"

    if [[ -z "$NEST_ID" ]]; then
        error "Gagal membuat Nest."
        echo "$CREATE_RESPONSE" | jq . 2>/dev/null || echo "$CREATE_RESPONSE"
        exit 1
    fi

    success "Nest berhasil dibuat. ID: $NEST_ID"
fi

# ------------------------------------------------------------
# Download Egg
# ------------------------------------------------------------

EGG_URL="${GITHUB_RAW_BASE%/}/${EGG_FILE#/}"
TEMP_EGG="$(mktemp --suffix=.json)"
trap 'rm -f "$TEMP_EGG"' EXIT

echo
info "Mengambil Egg:"
echo "  $EGG_URL"

curl -fsSL "$EGG_URL" -o "$TEMP_EGG" || {
    error "Gagal mengambil Egg dari GitHub."
    echo "Pastikan file tersedia di:"
    echo "  $EGG_FILE"
    exit 1
}

jq empty "$TEMP_EGG" >/dev/null 2>&1 || {
    error "File Egg bukan JSON yang valid."
    exit 1
}

EGG_FORMAT="$(jq -r '.meta.version // empty' "$TEMP_EGG")"
EGG_NAME="$(jq -r '.name // empty' "$TEMP_EGG")"
EGG_AUTHOR="$(jq -r '.author // empty' "$TEMP_EGG")"

[[ "$EGG_FORMAT" == "PTDL_v2" ]] || \
    die "Egg harus PTDL_v2. Format ditemukan: ${EGG_FORMAT:-unknown}"

[[ -n "$EGG_NAME" ]] || die "Field 'name' tidak ditemukan di Egg."

success "Egg valid."
echo "  Name   : $EGG_NAME"
echo "  Author : ${EGG_AUTHOR:-unknown}"
echo "  Format : $EGG_FORMAT"

# ------------------------------------------------------------
# Import Egg
#
# Pterodactyl expects the Egg JSON as multipart file upload.
# This matches the Axyluz installer implementation:
#   POST /api/application/nests/{nest}/import
#
# Try "file" first, then "import_file" on HTTP 422.
# ------------------------------------------------------------

import_egg() {
    local field="$1"

    curl -sS \
        -X POST \
        "${PANEL_URL}/api/application/nests/${NEST_ID}/import" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Accept: ${API_ACCEPT}" \
        -H "User-Agent: Axyluz-AutoNest/1.0" \
        -F "${field}=@${TEMP_EGG};type=application/json" \
        -w $'\n__HTTP_STATUS__:%{http_code}\n'
}

echo
info "Mengimport Egg ke Nest #${NEST_ID}..."

RESPONSE="$(import_egg "file")"
STATUS="$(echo "$RESPONSE" | sed -n 's/^__HTTP_STATUS__://p' | tail -n1)"
BODY="$(echo "$RESPONSE" | sed '/^__HTTP_STATUS__:/d')"

if [[ "$STATUS" == "2"* ]]; then
    success "Egg berhasil diimport ke Nest '$NEST_NAME'."
else
    # Match Axyluz installer: only retry the alternate field on 422.
    if [[ "$STATUS" == "422" ]]; then
        warn "Field upload 'file' ditolak (422). Mencoba 'import_file'..."

        RESPONSE="$(import_egg "import_file")"
        STATUS="$(echo "$RESPONSE" | sed -n 's/^__HTTP_STATUS__://p' | tail -n1)"
        BODY="$(echo "$RESPONSE" | sed '/^__HTTP_STATUS__:/d')"

        if [[ "$STATUS" == "2"* ]]; then
            success "Egg berhasil diimport ke Nest '$NEST_NAME'."
        else
            error "Import Egg gagal. HTTP $STATUS"
            echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
            exit 1
        fi
    else
        error "Import Egg gagal. HTTP ${STATUS:-unknown}"
        echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
        exit 1
    fi
fi

# ------------------------------------------------------------
# Verify Nest / Egg
# ------------------------------------------------------------

echo
info "Memverifikasi Nest..."

VERIFY_NEST="$(api_json GET "/nests/${NEST_ID}" 2>/dev/null || true)"

if echo "$VERIFY_NEST" | jq -e '.attributes.id' >/dev/null 2>&1; then
    success "Nest terverifikasi."
else
    warn "Nest berhasil dibuat/import, tetapi verifikasi detail Nest gagal."
fi

echo
echo "=========================================="
echo "              SELESAI"
echo "=========================================="
echo "Nest ID   : $NEST_ID"
echo "Nest Name : $NEST_NAME"
echo "Egg       : $EGG_NAME"
echo "Status    : Imported"
echo "=========================================="
