#!/usr/bin/env bash
# Downloads the object detector that lets motion be limited to people and vehicles:
# ONNX Runtime (MIT licence, Microsoft) and the YOLOX models (Apache-2.0, Megvii).
# ONNX Runtime comes from its GitHub release, or, when that is unavailable, from
# Microsoft's official NuGet package (the same build). Every file is checked
# against a known SHA-256 sum, and downloads are kept in ~/.cache/ipvexa-ai.
#
# Usage: scripts/get-ai.sh
# Prints the folder holding the files to install (the server's "ai" folder).
# The detector runs entirely on the server; nothing is sent anywhere.
set -euo pipefail

ORT_VERSION="1.31.1"
# Microsoft.ML.OnnxRuntime on nuget.org holds the libraries for every platform.
NUGET_URL="https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$ORT_VERSION/microsoft.ml.onnxruntime.$ORT_VERSION.nupkg"
NUGET_FILE="microsoft.ml.onnxruntime.$ORT_VERSION.nupkg"
NUGET_SHA="6871ccbc97f3d5bdb4095a1dcec33aa78d56f6ed8de5980ef5fa1d9f2e7c679a"
YOLOX_RELEASE="https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    ort="onnxruntime-linux-x64-$ORT_VERSION"
    ort_sha="c849e36a1ef3e22d4ff217b9d1ce4a3cf5b9467b975610913ae959ad5b16bdc9"
    lib="libonnxruntime.so.$ORT_VERSION"
    nuget_lib="runtimes/linux-x64/native/libonnxruntime.so" ;;
  Linux-aarch64|Linux-arm64)
    ort="onnxruntime-linux-aarch64-$ORT_VERSION"
    ort_sha="5317505e2da99be65f8e2775ba3c2afd6d2961fd78aba1bd8f56159f48820c78"
    lib="libonnxruntime.so.$ORT_VERSION"
    nuget_lib="runtimes/linux-arm64/native/libonnxruntime.so" ;;
  Darwin-arm64)
    ort="onnxruntime-osx-arm64-$ORT_VERSION"
    ort_sha="2e1344a1926ee50eb25b38153cb6992c3567515aef0e677a1a520a1798896d6f"
    lib="libonnxruntime.$ORT_VERSION.dylib"
    nuget_lib="runtimes/osx-arm64/native/libonnxruntime.dylib" ;;
  *)
    echo "no object detector download for $(uname -s) $(uname -m)" >&2
    exit 1 ;;
esac

cache="${XDG_CACHE_HOME:-$HOME/.cache}/ipvexa-ai"
mkdir -p "$cache"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

# fetch URL FILE SHA256: download into the cache unless a good copy is there.
fetch() {
  local url="$1" file="$cache/$2" sum="$3"
  if [[ -f "$file" && "$(sha256 "$file")" == "$sum" ]]; then
    return 0
  fi
  echo "    downloading $2" >&2
  curl -fL --retry 3 --connect-timeout 20 -sS -o "$file.part" "$url"
  if [[ "$(sha256 "$file.part")" != "$sum" ]]; then
    rm -f "$file.part"
    echo "$2: the download doesn't match its known checksum" >&2
    return 1
  fi
  mv "$file.part" "$file"
}

# unzip FILE MEMBER DEST: extract one file from a zip (a .nupkg is a zip).
unzip_one() {
  if command -v unzip >/dev/null; then unzip -p "$1" "$2" > "$3"
  else python3 -c 'import sys, zipfile; open(sys.argv[3], "wb").write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))' "$1" "$2" "$3"
  fi
}

out="$cache/files"
rm -rf "$out" "$cache/unpack"
mkdir -p "$out" "$cache/unpack"
if fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/$ort.tgz" "$ort.tgz" "$ort_sha" 2>/dev/null; then
  tar -xzf "$cache/$ort.tgz" -C "$cache/unpack" "$ort/lib/$lib" "$ort/LICENSE"
  cp "$cache/unpack/$ort/lib/$lib" "$out/"
  cp "$cache/unpack/$ort/LICENSE" "$out/LICENSE-onnxruntime.txt"
else
  echo "    ONNX Runtime isn't on GitHub; using Microsoft's NuGet package instead (about 160 MB)" >&2
  rm -f "$cache/$ort.tgz.part"
  fetch "$NUGET_URL" "$NUGET_FILE" "$NUGET_SHA"
  unzip_one "$cache/$NUGET_FILE" "$nuget_lib" "$out/$lib"
  unzip_one "$cache/$NUGET_FILE" LICENSE "$out/LICENSE-onnxruntime.txt"
fi
rm -rf "$cache/unpack"
fetch "$YOLOX_RELEASE/yolox_s.onnx" yolox_s.onnx c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063
fetch "$YOLOX_RELEASE/yolox_tiny.onnx" yolox_tiny.onnx 427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7
cp "$cache/yolox_s.onnx" "$cache/yolox_tiny.onnx" "$out/"
cat > "$out/README.txt" <<EOF
IPvexa object detector (used to limit motion to people and vehicles).
ONNX Runtime $ORT_VERSION: https://github.com/microsoft/onnxruntime (MIT licence, see LICENSE-onnxruntime.txt)
YOLOX models: https://github.com/Megvii-BaseDetection/YOLOX (Apache License 2.0)
Everything runs on this machine. Delete this folder to turn the detector off.
EOF
echo "$out"
