#!/usr/bin/env bash
set -euo pipefail
# Source pin: LibRaw 0.22.0 annotated tag dereferences to this commit.
# Build real iPhoneOS ARM64 libraw.a. Do not use an empty stub library.
PINNED_SHA=0b56545a4f828743f28a4345cdfdd4c49f9f9a2a
ROOT=ios/build/vendor/LibRaw
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p ios/build/vendor
if [[ ! -d "$ROOT/.git" ]]; then
  git clone --quiet --depth 1 --branch 0.22.0 \
      https://github.com/LibRaw/LibRaw.git "$ROOT"
fi
ACTUAL="$(git -C "$ROOT" rev-parse HEAD)"
test "$ACTUAL" = "$PINNED_SHA" || {
  echo "::error::LibRaw source SHA differs: $ACTUAL expected $PINNED_SHA"
  exit 1
}
echo "PINNED LibRaw 0.22.0 sha=$ACTUAL"
pushd "$ROOT"
# Makefile.dist includes Fuji compressed & X-Trans decoders; compile all
# library sources with iPhoneOS SDK, no host macOS objects or OpenMP.
make -f Makefile.dist -j 4 lib/libraw.a \
  CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)" \
  CFLAGS="-O2 -I. -w -arch arm64 -isysroot $SDK -miphoneos-version-min=16.5 -DUSE_ZLIB"
test -s lib/libraw.a
xcrun lipo -archs lib/libraw.a | grep -w arm64
# Fail if Fuji compressed decoder was not assembled into the native archive.
xcrun ar -t lib/libraw.a | grep -Fx 'fuji_compressed.o'
xcrun ar -t lib/libraw.a | grep -Fx 'xtrans_demosaic.o'
popd
echo "PASS Build94 real 0.22.0 iPhoneOS libraw.a with Fuji compressed decoder"
