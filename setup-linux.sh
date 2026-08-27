#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Derive the home from $USER so no literal username is baked into paths.
USER_HOME="${ER_USER_HOME:-$(getent passwd "$USER" 2>/dev/null | cut -d: -f6)}"
: "${USER_HOME:=$HOME}"
readonly USER_HOME
readonly STEAM_ROOT="${ER_STEAM_ROOT:-$USER_HOME/.steam/steam}"
readonly GAME_DIR="${ER_GAME_DIR:-$STEAM_ROOT/steamapps/common/ELDEN RING/Game}"
# Only treat a mod folder as active when the game is actually loading
# loose-file mods (loader DLL present) and the mod genuinely replaces
# game data (its regulation.bin differs from the game's).
DEFAULT_MOD_DIR=""
mod_loader_present=false
for dll in dxgi.dll winmm.dll dinput8.dll version.dll unsteam.dll; do
    if [[ -r "$GAME_DIR/$dll" ]]; then
        mod_loader_present=true
        break
    fi
done
if [[ "$mod_loader_present" == true ]]; then
    shopt -s nullglob
    mod_candidates=()
    for pattern in /mnt/media/*/Games/ERR/mod \
                   /run/media/*/GAMES/ERR/mod \
                   /media/*/Games/ERR/mod \
                   "$USER_HOME/ERR/mod" \
                   /mnt/*/Games/ERR/mod; do
        for cand in $pattern; do
            if [[ -e "$cand" && -d "$cand" && -r "$cand/regulation.bin" ]] \
               && ! cmp -s "$cand/regulation.bin" "$GAME_DIR/regulation.bin"; then
                mod_candidates+=("$cand")
            fi
        done
    done
    shopt -u nullglob
    # Prefer the canonical ERR directory over ERRv* backups.
    for cand in "${mod_candidates[@]}"; do
        if [[ "$cand" == */ERR/mod ]]; then
            DEFAULT_MOD_DIR="$cand"
            break
        fi
    done
    if [[ -z "$DEFAULT_MOD_DIR" && "${#mod_candidates[@]}" -gt 0 ]]; then
        DEFAULT_MOD_DIR="${mod_candidates[0]}"
    fi
fi
readonly MOD_DIR="${ER_MOD_DIR:-$DEFAULT_MOD_DIR}"
readonly NATIVE_DIR="$ROOT/cache/native-oodle"
readonly SOURCE_DIR="$NATIVE_DIR/source"
readonly BUILD_DIR="$NATIVE_DIR/build"
readonly VENV_DIR="$ROOT/cache/python"
readonly PYTHON="$VENV_DIR/bin/python"
readonly LIB="$BUILD_DIR/liblinoodle.so"
readonly LINOODLE_COMMIT=90b8d825f7f89272f03f52b5d1db4708e07eb83f

require_command() {
    command -v "$1" >/dev/null || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

check_host() {
    local command_name
    for command_name in git cmake clang clang++ uv; do
        require_command "$command_name"
    done
    test -r "$GAME_DIR/eldenring.exe" || {
        printf 'Elden Ring was not found at: %s\n' "$GAME_DIR" >&2
        exit 1
    }
    test -r "$GAME_DIR/regulation.bin" || {
        printf 'regulation.bin was not found at: %s\n' "$GAME_DIR" >&2
        exit 1
    }
    test -r "$GAME_DIR/oo2core_6_win64.dll" || {
        printf 'The game Oodle DLL was not found at: %s\n' "$GAME_DIR" >&2
        exit 1
    }
    if [[ -n "$MOD_DIR" && ! -r "$MOD_DIR/regulation.bin" ]]; then
        printf 'ERR mod files were not found at: %s\n' "$MOD_DIR" >&2
        exit 1
    fi
}

display_path() {
    local p="$1"
    printf '%s' "${p/#"$USER_HOME"/\~}"
}

if [[ "${1:-}" == "--check" ]]; then
    check_host
    printf 'Game: %s\n' "$(display_path "$GAME_DIR")"
    printf 'Mod files: %s\n' "$(display_path "${MOD_DIR:-none}")"
    printf 'Native Oodle: %s\n' "$(display_path "$LIB")"
    exit 0
fi

check_host

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    mkdir -p "$NATIVE_DIR"
    git clone --quiet --recurse-submodules https://github.com/McSimp/linoodle.git "$SOURCE_DIR"
fi
git -C "$SOURCE_DIR" checkout --quiet "$LINOODLE_COMMIT"
git -C "$SOURCE_DIR" submodule update --init --recursive --quiet

if [[ ! -f "$LIB" ]]; then
    cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        '-DCMAKE_CXX_FLAGS=-include cstdint -include utility -Wno-error'
    cmake --build "$BUILD_DIR" --target linoodle -j"$(nproc)"
fi

mkdir -p "$NATIVE_DIR/runtime"
ln -sfn "$GAME_DIR/oo2core_6_win64.dll" \
    "$NATIVE_DIR/runtime/oo2core_8_win64.dll"

uv venv --quiet --allow-existing "$VENV_DIR"
uv pip install --quiet --python "$PYTHON" \
    zstandard pycryptodome pillow texture2ddecoder numpy

export ER_GAME_DIR="$GAME_DIR"
export ER_MOD_DIR="$MOD_DIR"
export ER_LINOODLE="$LIB"
cd "$NATIVE_DIR/runtime"

printf '\n[1/5] Extracting base map tiles...\n'
"$PYTHON" "$ROOT/tools/extract_tiles.py" --game-dir "$GAME_DIR"
printf '\n[2/5] Building marker data...\n'
"$PYTHON" "$ROOT/tools/build_markers.py" "$GAME_DIR"
printf '\n[3/5] Indexing map files...\n'
"$PYTHON" "$ROOT/tools/enumerate_maps.py"
printf '\n[4/5] Extracting item locations...\n'
"$PYTHON" "$ROOT/tools/extract_items.py" --game-dir "$GAME_DIR" --mod-dir "$MOD_DIR"
printf '\n[5/5] Extracting map icons...\n'
"$PYTHON" "$ROOT/tools/extract_icons.py" --game-dir "$GAME_DIR" --mod-dir "$MOD_DIR"
printf '\n[6/6] Extracting ERR rune/ember pieces...\n'
"$PYTHON" "$ROOT/tools/extract_pieces.py" --game-dir "$GAME_DIR" --mod-dir "$MOD_DIR"

printf '\nSetup complete. Run ./start-map.sh to open the live map.\n'
