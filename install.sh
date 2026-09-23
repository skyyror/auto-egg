#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PTERODACTYL AUTO NEST + EGG IMPORT (standalone / CLI version)
#
# Ini adalah versi command-line dari tahap IMPORT_EGG yang otomatis
# dijalankan oleh bot Axyluz saat /installpanelauto. Pakai script ini
# untuk panel yang SUDAH ADA (dibuat manual / lewat /installpanel
# legacy) supaya Nest & Egg-nya persis sama dengan hasil /installpanelauto.
#
# Sinkron dengan lib/autoNode.js + index.js:
# - findOrCreateNest(): cari Nest by name (case-insensitive), buat kalau
#   belum ada. Default nama & deskripsi SAMA PERSIS dengan config.js:
#     PTERODACTYL_NEST_NAME        = AUTONESTBYAXYLUZ
#     PTERODACTYL_NEST_DESCRIPTION = Nest dibuat otomatis oleh Axyluz Installer
# - readAllBundledEggs(): scan SEMUA file *.json di folder eggs/, bukan
#   cuma 1 file. Nambah egg baru = taruh .json di eggs/, script ini
#   otomatis ikut import tanpa perlu diedit.
# - importEgg(): POST /api/application/nests/{nest}/import, multipart
#   field "file" dulu, fallback ke "import_file" kalau HTTP 422. Egg yang
#   gagal tidak menggagalkan egg lain (sama seperti bot).
# ============================================================

# --- Sumber egg -----------------------------------------------------
# 1) Kalau folder eggs/ ada di lokal (mis. script ini dijalankan dari
#    dalam project axyluz-installer-fixed/, folder yang sama persis
#    dipakai bot untuk /installpanelauto), pakai itu -> otomatis sinkron,
#    tidak perlu setting apa pun.
# 2) Kalau tidak ada, fallback ambil daftar file eggs/*.json dari GitHub
#    lewat Contents API (bukan 1 file hardcoded), supaya tetap ikut kalau
#    ada egg baru ditambahkan ke repo.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
EGGS_LOCAL_DIR="${EGGS_LOCAL_DIR:-}"
GITHUB_OWNER="${GITHUB_OWNER:-USERNAME}"
GITHUB_REPO="${GITHUB_REPO:-REPOSITORY}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_EGGS_PATH="${GITHUB_EGGS_PATH:-eggs}"

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
echo "      (sinkron dengan /installpanelauto)"
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
# Kumpulkan daftar egg yang mau diimport
#
# TEMP_DIR menampung semua egg (lokal langsung dipakai / GitHub
# didownload dulu ke sini), lalu diimport satu per satu di bawah.
# ------------------------------------------------------------

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo
EGG_SOURCE=""

# 1) Coba folder lokal dulu: ./eggs, lalu eggs/ sejajar dengan script ini.
for candidate in "$EGGS_LOCAL_DIR" "$(pwd)/eggs" "$SCRIPT_DIR/eggs"; do
    [[ -z "$candidate" ]] && continue
    if [[ -d "$candidate" ]] && compgen -G "${candidate}/*.json" >/dev/null 2>&1; then
        EGGS_LOCAL_DIR="$candidate"
        EGG_SOURCE="local"
        break
    fi
done

if [[ "$EGG_SOURCE" == "local" ]]; then
    info "Folder eggs/ ditemukan secara lokal: $EGGS_LOCAL_DIR"
    info "(folder yang sama persis dipakai bot untuk /installpanelauto)"
    cp "$EGGS_LOCAL_DIR"/*.json "$TEMP_DIR"/
else
    info "Folder eggs/ lokal tidak ditemukan. Mengambil daftar egg dari GitHub..."
    info "Repo: ${GITHUB_OWNER}/${GITHUB_REPO} (branch: ${GITHUB_BRANCH}, path: ${GITHUB_EGGS_PATH})"

    LISTING="$(
        curl -sS \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${GITHUB_EGGS_PATH}?ref=${GITHUB_BRANCH}" \
            2>/dev/null || true
    )"

    if ! echo "$LISTING" | jq -e 'type == "array"' >/dev/null 2>&1; then
        error "Gagal mengambil daftar folder eggs/ dari GitHub."
        echo "Set GITHUB_OWNER / GITHUB_REPO / GITHUB_BRANCH dengan benar, atau"
        echo "jalankan script ini dari dalam folder project (yang punya folder eggs/)."
        echo "$LISTING" | jq . 2>/dev/null || echo "$LISTING"
        exit 1
    fi

    mapfile -t DOWNLOAD_URLS < <(
        echo "$LISTING" | jq -r '.[] | select(.type == "file" and (.name | test("\\.json$"; "i"))) | .download_url'
    )

    if [[ "${#DOWNLOAD_URLS[@]}" -eq 0 ]]; then
        die "Tidak ada file .json di folder eggs/ pada repo GitHub tersebut."
    fi

    for url in "${DOWNLOAD_URLS[@]}"; do
        fname="$(basename "$url")"
        info "  Mengunduh: $fname"
        curl -fsSL "$url" -o "${TEMP_DIR}/${fname}" || {
            warn "  Gagal mengunduh $fname, dilewati."
        }
    done
fi

EGG_FILES=("${TEMP_DIR}"/*.json)
if [[ ! -e "${EGG_FILES[0]}" ]]; then
    die "Tidak ada egg yang bisa diimport."
fi

echo
info "Ditemukan ${#EGG_FILES[@]} egg untuk diimport ke Nest '$NEST_NAME':"
for f in "${EGG_FILES[@]}"; do
    echo "  - $(basename "$f")"
done

# ------------------------------------------------------------
# Import Egg
#
# Pterodactyl expects the Egg JSON as multipart file upload:
#   POST /api/application/nests/{nest}/import
# Try "file" first, then "import_file" on HTTP 422 - sama seperti
# autoNode.importEgg() di bot. Satu egg gagal TIDAK menghentikan egg
# lain, sama seperti perilaku /installpanelauto.
# ------------------------------------------------------------

import_egg() {
    local field="$1"
    local egg_file="$2"

    curl -sS \
        -X POST \
        "${PANEL_URL}/api/application/nests/${NEST_ID}/import" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Accept: ${API_ACCEPT}" \
        -H "User-Agent: Axyluz-AutoNest/1.0" \
        -F "${field}=@${egg_file};type=application/json" \
        -w $'\n__HTTP_STATUS__:%{http_code}\n'
}

OK_EGGS=()
FAILED_EGGS=()

echo
info "Mengimport egg ke Nest #${NEST_ID}..."
echo

for egg_file in "${EGG_FILES[@]}"; do
    fname="$(basename "$egg_file")"

    if ! jq empty "$egg_file" >/dev/null 2>&1; then
        warn "  [$fname] bukan JSON valid, dilewati."
        FAILED_EGGS+=("$fname (JSON tidak valid)")
        continue
    fi

    egg_format="$(jq -r '.meta.version // empty' "$egg_file")"
    egg_name="$(jq -r '.name // empty' "$egg_file")"

    if [[ "$egg_format" != "PTDL_v2" ]]; then
        warn "  [$fname] bukan format PTDL_v2 (ditemukan: ${egg_format:-unknown}), dilewati."
        FAILED_EGGS+=("$fname (format bukan PTDL_v2)")
        continue
    fi
    if [[ -z "$egg_name" ]]; then
        warn "  [$fname] field 'name' tidak ditemukan, dilewati."
        FAILED_EGGS+=("$fname (field name kosong)")
        continue
    fi

    RESPONSE="$(import_egg "file" "$egg_file")"
    STATUS="$(echo "$RESPONSE" | sed -n 's/^__HTTP_STATUS__://p' | tail -n1)"
    BODY="$(echo "$RESPONSE" | sed '/^__HTTP_STATUS__:/d')"

    if [[ "$STATUS" != "2"* && "$STATUS" == "422" ]]; then
        RESPONSE="$(import_egg "import_file" "$egg_file")"
        STATUS="$(echo "$RESPONSE" | sed -n 's/^__HTTP_STATUS__://p' | tail -n1)"
        BODY="$(echo "$RESPONSE" | sed '/^__HTTP_STATUS__:/d')"
    fi

    if [[ "$STATUS" == "2"* ]]; then
        success "  [$fname] Egg '$egg_name' berhasil diimport."
        OK_EGGS+=("$egg_name ($fname)")
    else
        error "  [$fname] Import gagal. HTTP ${STATUS:-unknown}"
        echo "$BODY" | jq -c . 2>/dev/null || echo "$BODY"
        FAILED_EGGS+=("$fname (HTTP ${STATUS:-unknown})")
    fi
done

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
echo "Nest ID     : $NEST_ID"
echo "Nest Name   : $NEST_NAME"
echo "Egg sukses  : ${#OK_EGGS[@]}"
for e in "${OK_EGGS[@]}"; do echo "  \u2714 $e"; done
if [[ "${#FAILED_EGGS[@]}" -gt 0 ]]; then
    echo "Egg gagal   : ${#FAILED_EGGS[@]}"
    for e in "${FAILED_EGGS[@]}"; do echo "  \u2718 $e"; done
fi
echo "=========================================="

if [[ "${#OK_EGGS[@]}" -eq 0 ]]; then
    exit 1
fi
