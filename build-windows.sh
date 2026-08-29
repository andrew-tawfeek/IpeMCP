#!/usr/bin/env bash

# Build a portable 64-bit Windows bundle of Ipe 7.2.30.
# Run this script from an MSYS2 UCRT64 (recommended) or MINGW64 shell.

set -Eeuo pipefail

script_name="${0##*/}"
readonly script_name="${script_name##*\\}"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

die() {
  printf '%s: error: %s\n' "$script_name" "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

usage() {
  printf '%s\n' \
    "Usage: $script_name [options]" \
    "" \
    "Build Ipe as native 64-bit Windows executables with MSYS2/MinGW-w64." \
    "" \
    "Options:" \
    "  --clean        Clean Ipe's MinGW build tree before compiling" \
    "  --skip-deps    Do not install missing MSYS2 packages with pacman" \
    "  --jobs N       Run N parallel compiler jobs (default: CPU count)" \
    "  --output DIR   Write the runnable bundle to DIR" \
    "  -h, --help     Show this help" \
    "" \
    "Environment overrides:" \
    "  IPE_SOURCE_DIR   Ipe source root (default: ./ipe-7.2.30)" \
    "  IPE_OUTPUT_DIR   Bundle directory (default: ./dist/ipe-7.2.30-windows-x64)" \
    "  JOBS             Parallel compiler jobs" \
    "" \
    "Example (from an MSYS2 UCRT64 shell):" \
    "  ./$script_name --clean"
}

to_msys_path_from_wsl() {
  local windows_path drive rest
  windows_path="$(wslpath -w "$1")"
  drive="${windows_path:0:1}"
  rest="${windows_path:3}"
  rest="${rest//\\//}"
  printf '/%s/%s' "${drive,,}" "$rest"
}

forward_to_msys2_if_needed() {
  command -v pacman >/dev/null 2>&1 && return

  local msys_bash msys_workdir msys_script
  if [[ -r /proc/sys/kernel/osrelease ]] &&
     grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null &&
     [[ -x /mnt/c/msys64/usr/bin/bash.exe || -x /c/msys64/usr/bin/bash.exe ]]; then
    if [[ -x /mnt/c/msys64/usr/bin/bash.exe ]]; then
      msys_bash=/mnt/c/msys64/usr/bin/bash.exe
    else
      msys_bash=/c/msys64/usr/bin/bash.exe
    fi
    msys_workdir="$(to_msys_path_from_wsl "$PWD")"
    msys_script="$(to_msys_path_from_wsl "$script_dir/$script_name")"
    export WSLENV="${WSLENV:+$WSLENV:}MSYSTEM:CHERE_INVOKING"
  elif [[ -x /c/msys64/usr/bin/bash.exe ]]; then
    msys_bash=/c/msys64/usr/bin/bash.exe
    msys_workdir="$PWD"
    msys_script="$script_dir/$script_name"
  else
    die "MSYS2 was not found. Install it with: winget install --id MSYS2.MSYS2 --exact"
  fi

  note "Forwarding this build to the MSYS2 UCRT64 toolchain"
  export MSYSTEM=UCRT64
  export CHERE_INVOKING=1
  exec "$msys_bash" -lc 'cd -- "$1" && shift && exec "$@"' \
    bash "$msys_workdir" "$msys_script" "$@"
}

# Git Bash calls itself MINGW64 but does not include pacman or a compiler.
# WSL is also not the native Windows build environment. Transparently re-run
# under an installed MSYS2 UCRT64 shell in either case.
if [[ "${1:-}" != "-h" && "${1:-}" != "--help" ]]; then
  forward_to_msys2_if_needed "$@"
fi

clean=0
install_deps=1
jobs="${JOBS:-}"
output_arg="${IPE_OUTPUT_DIR:-}"

while (($#)); do
  case "$1" in
    --clean)
      clean=1
      shift
      ;;
    --skip-deps)
      install_deps=0
      shift
      ;;
    --jobs)
      (($# >= 2)) || die "--jobs requires a value"
      jobs="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || die "--output requires a directory"
      output_arg="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

case "${MSYSTEM:-}" in
  UCRT64)
    package_prefix="mingw-w64-ucrt-x86_64"
    expected_prefix="/ucrt64"
    ;;
  MINGW64)
    package_prefix="mingw-w64-x86_64"
    expected_prefix="/mingw64"
    ;;
  *)
    die "run this script in an MSYS2 UCRT64 (recommended) or MINGW64 shell"
    ;;
esac

mingw_prefix="${MINGW_PREFIX:-$expected_prefix}"
[[ -d "$mingw_prefix/bin" ]] || die "MinGW prefix not found: $mingw_prefix"

source_dir="${IPE_SOURCE_DIR:-$script_dir/ipe-7.2.30}"
[[ -f "$source_dir/src/Makefile" ]] || \
  die "Ipe source tree not found at $source_dir (set IPE_SOURCE_DIR to override)"
source_dir="$(cd -- "$source_dir" && pwd -P)"

if [[ -z "$jobs" ]]; then
  jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "job count must be a positive integer: $jobs"

if ((install_deps)); then
  command -v pacman >/dev/null 2>&1 || die "pacman was not found; use an MSYS2 shell"
  packages=(
    make
    "${package_prefix}-binutils"
    "${package_prefix}-gcc"
    "${package_prefix}-pkgconf"
    "${package_prefix}-zlib"
    "${package_prefix}-freetype"
    "${package_prefix}-cairo"
    "${package_prefix}-lua54"
    "${package_prefix}-libspiro"
    "${package_prefix}-gsl"
    "${package_prefix}-icoutils"
  )
  note "Installing required MSYS2 packages (already-installed packages are skipped)"
  pacman --sync --needed --noconfirm "${packages[@]}"
fi

required_commands=(make g++ gcc windres strip objdump pkg-config icotool find cygpath)
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || \
    die "required command not found: $command_name"
done

gxx_path="$(command -v g++)"
[[ "$gxx_path" == "$mingw_prefix"/bin/* ]] || \
  die "g++ must come from $mingw_prefix/bin, but found $gxx_path"

pkg_modules=(zlib freetype2 cairo lua5.4 libspiro gsl)
for module in "${pkg_modules[@]}"; do
  pkg-config --exists "$module" || die "pkg-config module not found: $module"
done

make_vars=(
  "COMSPEC=1"
  "IPEDEPS=$mingw_prefix"
  "CXX=g++"
  "CC=gcc"
  # A Git Bash -> MSYS2 handoff can leave POSIX pipe descriptors that the
  # native windres subprocess cannot inherit. A temporary preprocessor file
  # is equally valid and works reliably from Git Bash, WSL, and MSYS2 itself.
  "WINDRES=windres --use-temp-file"
  "ZLIB_CFLAGS=$(pkg-config --cflags zlib)"
  "ZLIB_LIBS=$(pkg-config --libs zlib)"
  "FREETYPE_CFLAGS=$(pkg-config --cflags freetype2)"
  "FREETYPE_LIBS=$(pkg-config --libs freetype2)"
  "CAIRO_CFLAGS=$(pkg-config --cflags cairo)"
  "CAIRO_LIBS=$(pkg-config --libs cairo)"
  "LUA_CFLAGS=$(pkg-config --cflags lua5.4)"
  "LUA_LIBS=$(pkg-config --libs lua5.4)"
  "SPIRO_CFLAGS=$(pkg-config --cflags libspiro)"
  "SPIRO_LIBS=$(pkg-config --libs libspiro)"
  "GSL_CFLAGS=$(pkg-config --cflags gsl)"
  "GSL_LIBS=$(pkg-config --libs gsl)"
)

if ((clean)); then
  note "Cleaning the MinGW build tree"
  make --directory="$source_dir/src" "${make_vars[@]}" clean
fi

# The top-level makefile only declares this prerequisite for cross-builds,
# while the native MinGW resource files require it as well.
icon_file="$source_dir/build/ipe.ico"
if [[ ! -f "$icon_file" || "$source_dir/artwork/ipe.iconset/icon_512x512.png" -nt "$icon_file" ]]; then
  note "Creating the Windows application icon"
  mkdir -p -- "${icon_file%/*}"
  icotool -c \
    "$source_dir/artwork/ipe.iconset/icon_16x16.png" \
    "$source_dir/artwork/ipe.iconset/icon_32x32.png" \
    "$source_dir/artwork/ipe.iconset/icon_64x64.png" \
    "$source_dir/artwork/ipe.iconset/icon_128x128.png" \
    "$source_dir/artwork/ipe.iconset/icon_256x256.png" \
    "$source_dir/artwork/ipe.iconset/icon_512x512.png" \
    -o "$icon_file"
fi

note "Compiling Ipe with $jobs parallel jobs"
make --directory="$source_dir/src" --jobs="$jobs" "${make_vars[@]}"

# Ipe's native 64-bit Windows makefiles always use this directory name,
# including when the newer UCRT64 toolchain is selected.
build_dir="$source_dir/mingw64"
[[ -f "$build_dir/bin/ipe.exe" ]] || die "build completed without producing ipe.exe"

if [[ -z "$output_arg" ]]; then
  output_arg="$script_dir/dist/ipe-7.2.30-windows-x64"
elif [[ "$output_arg" != /* ]]; then
  output_arg="$PWD/$output_arg"
fi

output_parent="$(dirname -- "$output_arg")"
output_name="$(basename -- "$output_arg")"
mkdir -p -- "$output_parent"
output_parent="$(cd -- "$output_parent" && pwd -P)"
bundle_dir="$output_parent/$output_name"

case "$bundle_dir" in
  /|"$script_dir"|"$source_dir"|"$source_dir"/*)
    die "refusing unsafe output directory: $bundle_dir"
    ;;
esac

bundle_marker="$bundle_dir/.ipe-windows-bundle"
if [[ -e "$bundle_dir" ]]; then
  [[ -f "$bundle_marker" ]] || \
    die "output directory already exists and was not created by this script: $bundle_dir"
  rm -rf -- "$bundle_dir"
fi

note "Assembling runnable bundle at $bundle_dir"
install -d "$bundle_dir/bin" "$bundle_dir/ipelets" "$bundle_dir/lua" \
  "$bundle_dir/scripts" "$bundle_dir/styles" "$bundle_dir/icons" \
  "$bundle_dir/doc" "$bundle_dir/mcp"
printf 'Created by %s\n' "$script_name" >"$bundle_marker"

cp -a "$build_dir/bin/." "$bundle_dir/bin/"
if [[ -d "$build_dir/ipelets" ]]; then
  cp -a "$build_dir/ipelets/." "$bundle_dir/ipelets/"
fi
cp -a "$source_dir/src/ipe/lua/." "$bundle_dir/lua/"
cp -a "$source_dir/src/ipelets/lua/"*.lua "$bundle_dir/ipelets/"
cp -a "$source_dir/scripts/." "$bundle_dir/scripts/"
cp -a "$source_dir/styles/"*.isy "$bundle_dir/styles/"
cp -a "$source_dir/artwork/icons.ipe" "$source_dir/artwork/ipe_logo.ipe" \
  "$source_dir/artwork/ipe.iconset/icon_128x128.png" "$bundle_dir/icons/"
cp -a "$source_dir/doc/gpl.txt" "$bundle_dir/doc/LICENSE.txt"
cp -a "$source_dir/README.md" "$bundle_dir/README.md"
cp -a "$script_dir/mcp/." "$bundle_dir/mcp/"
cp -a "$script_dir/WINDOWS.md" "$bundle_dir/README-WINDOWS.md"

# Copy every non-system DLL imported by the executables, Ipe libraries, and
# ipelets. Recursing over newly copied DLLs makes the bundle independent of an
# MSYS2 installation at runtime.
declare -A queued=()
declare -a pe_queue=()

enqueue_pe() {
  local pe_file="$1"
  local pe_key
  pe_key="$(printf '%s' "$pe_file" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${queued[$pe_key]+x}" ]]; then
    queued[$pe_key]=1
    pe_queue+=("$pe_file")
  fi
}

find_named_file() {
  local search_dir="$1"
  local filename="$2"
  find "$search_dir" -maxdepth 1 -type f -iname "$filename" -print -quit
}

while IFS= read -r pe_file; do
  enqueue_pe "$pe_file"
done < <(find "$bundle_dir/bin" "$bundle_dir/ipelets" -maxdepth 1 -type f \
  \( -iname '*.exe' -o -iname '*.dll' \) -print)

windows_root="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")"
missing_dlls=()
queue_index=0
while ((queue_index < ${#pe_queue[@]})); do
  pe_file="${pe_queue[$queue_index]}"
  ((queue_index += 1))

  mapfile -t imports < <(
    objdump -p "$pe_file" 2>/dev/null |
      sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p'
  )

  for dll_name in "${imports[@]}"; do
    bundled_dll="$(find_named_file "$bundle_dir/bin" "$dll_name")"
    if [[ -n "$bundled_dll" ]]; then
      enqueue_pe "$bundled_dll"
      continue
    fi

    prefix_dll="$(find_named_file "$mingw_prefix/bin" "$dll_name")"
    if [[ -n "$prefix_dll" ]]; then
      cp -a "$prefix_dll" "$bundle_dir/bin/"
      copied_dll="$bundle_dir/bin/${prefix_dll##*/}"
      enqueue_pe "$copied_dll"
      continue
    fi

    system_dll="$(find_named_file "$windows_root/System32" "$dll_name")"
    if [[ -z "$system_dll" && "${dll_name,,}" != api-ms-win-* && \
          "${dll_name,,}" != ext-ms-win-* ]]; then
      missing_dlls+=("$dll_name (imported by ${pe_file##*/})")
    fi
  done
done

if ((${#missing_dlls[@]})); then
  printf '%s: unresolved runtime dependencies:\n' "$script_name" >&2
  printf '  %s\n' "${missing_dlls[@]}" >&2
  exit 1
fi

note "Stripping debug symbols from staged executables and DLLs"
while IFS= read -r pe_file; do
  strip --strip-unneeded "$pe_file"
done < <(find "$bundle_dir/bin" "$bundle_dir/ipelets" -maxdepth 1 -type f \
  \( -iname '*.exe' -o -iname '*.dll' \) -print)

printf '%s\n' \
  "Ipe version: 7.2.30" \
  "Target: 64-bit Windows ($MSYSTEM)" \
  "Compiler: $(g++ --version | sed -n '1p')" \
  "Built: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >"$bundle_dir/build-info.txt"

# Exercise the executable, Ipe DLLs, Lua DLL, and the bundled scripts path.
smoke_module="$bundle_dir/scripts/ipe_build_smoke.lua"
printf '%s\n' 'io.write(config.version)' >"$smoke_module"
set +e
smoke_output="$(
  cd -- "$bundle_dir/bin" &&
    PATH="$bundle_dir/bin:$PATH" ./ipescript.exe ipe_build_smoke 2>&1
)"
smoke_status=$?
set -e
rm -f -- "$smoke_module"

[[ $smoke_status -eq 0 && "$smoke_output" == *"Ipe 7.2.30"* ]] || \
  die "smoke test failed (exit $smoke_status): $smoke_output"

# Load the complete GUI Lua startup path without opening a window.  This catches
# failures in bundled ipelets and resources that ipescript does not exercise.
set +e
gui_smoke_output="$(
  cd -- "$bundle_dir/bin" &&
    PATH="$bundle_dir/bin:$PATH" ./ipe.exe -show-configuration 2>&1
)"
gui_smoke_status=$?
set -e

[[ $gui_smoke_status -eq 0 && "$gui_smoke_output" == *"Ipe 7.2.30"* && \
   "$gui_smoke_output" == *"Lua code:"* && \
   "$gui_smoke_output" == *"Ipelets:"* ]] || \
  die "GUI startup smoke test failed (exit $gui_smoke_status): $gui_smoke_output"

exe_count="$(find "$bundle_dir/bin" -maxdepth 1 -type f -iname '*.exe' | wc -l)"
dll_count="$(find "$bundle_dir/bin" -maxdepth 1 -type f -iname '*.dll' | wc -l)"
note "Build complete: $bundle_dir/bin/ipe.exe"
printf '    Bundle contains %s executables and %s runtime DLLs.\n' \
  "$exe_count" "$dll_count"
