#!/usr/bin/env bash
#
# mayhem/build.sh — build the Mbed TLS fuzz harnesses (libFuzzer + standalone reproducers) and the
# project's own test programs. Runs in the commit image as `mayhem` in /mayhem; offline-safe and
# re-runnable (every output lives in gitignored build-* directories or /mayhem/fuzz_*).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Mining layer (mine-d5e7465): one harness, fuzz_x509cn (mayhem/harness/fuzz_x509cn.c), built through the
# CMake target of upstream's fuzz_server, whose objects and link command already carry the test helpers and
# the deterministic clock (fuzz_common.c).
HARNESS=fuzz_x509cn
VEHICLE_SRC=fuzz_server
VEHICLE_DIR=build-fuzz/programs/fuzz

new_build_dir() {
  # Always configure from scratch: CMake discards a reused cache when it sees the compiler by name vs its
  # resolved path, and the reconfigured tree then fails to link (unresolved builtin-key hook).
  rm -rf "$1"
  mkdir -p "$1"
  printf '*\n' > "$1/.gitignore"   # keep the whole build dir out of git status; `git clean -X` removes it
}

# 1) Sanitized build of the project (default config plus a deterministic clock, as OSS-Fuzz builds it) including
#    the fuzz programs. -fsanitize=fuzzer-no-link adds SanCov to the library itself (the engine only
#    instruments the harness). MBEDTLS_TEST_SW_INET_PTON makes x509_crt.c use its own inet_pton (the code
#    the fix changed) instead of the platform's, as it does on platforms without inet_pton().
new_build_dir build-fuzz
cmake -S . -B build-fuzz \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DMBEDTLS_TEST_SW_INET_PTON" \
  -DMBEDTLS_FATAL_WARNINGS=OFF -DTF_PSA_CRYPTO_FATAL_WARNINGS=OFF \
  -DENABLE_PROGRAMS=ON -DENABLE_TESTING=OFF \
  -DMBEDTLS_CONFIG_SET="MBEDTLS_PLATFORM_TIME_ALT"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target $VEHICLE_SRC

# 1b) Replace the vehicle's harness object with ours, compiled with the exact flags CMake used.
fl="$VEHICLE_DIR/CMakeFiles/$VEHICLE_SRC.dir/flags.make"
defs="$(sed -n 's/^C_DEFINES = //p' "$fl")"
incs="$(sed -n 's/^C_INCLUDES = //p' "$fl")"
flags="$(sed -n 's/^C_FLAGS = //p' "$fl")"
eval "$CC $defs $incs -I$SRC/tf-psa-crypto/programs/fuzz $flags -c mayhem/harness/$HARNESS.c -o $VEHICLE_DIR/CMakeFiles/$VEHICLE_SRC.dir/$VEHICLE_SRC.c.o"

# 2) LeakSanitizer off-switch object (ASan + UBSan stay on and halting).
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o

# 3) Relink twice from CMake's own link command: the stock result uses the project's file-input driver
#    (fuzz_onefile.c) -> `$HARNESS-standalone`; swapping that driver for libFuzzer -> `$HARNESS`.
link="$(cat "$VEHICLE_DIR/CMakeFiles/$VEHICLE_SRC.dir/link.txt")"
( cd "$VEHICLE_DIR"
  eval "${link//-o $VEHICLE_SRC/-o $SRC/$HARNESS-standalone} $SRC/build-fuzz/lsan_off.o"
  link="${link//\"CMakeFiles\/$VEHICLE_SRC.dir\/__\/__\/tf-psa-crypto\/programs\/fuzz\/fuzz_onefile.c.o\"/}"
  link="${link//CMakeFiles\/$VEHICLE_SRC.dir\/fuzz_onefile.c.o/}"
  eval "${link//-o $VEHICLE_SRC/-o $SRC/$HARNESS $LIB_FUZZING_ENGINE} $SRC/build-fuzz/lsan_off.o" )

# 4) The project's own test programs, with NORMAL flags (default config, no sanitizers) in a separate
#    build tree, so mayhem/test.sh only has to run them.
new_build_dir build-tests
cmake -S . -B build-tests \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
  -DMBEDTLS_FATAL_WARNINGS=OFF -DTF_PSA_CRYPTO_FATAL_WARNINGS=OFF \
  -DENABLE_PROGRAMS=ON -DENABLE_TESTING=ON
# Keep this list in sync with TEST_SUITES in mayhem/test.sh.
cmake --build build-tests -j"$MAYHEM_JOBS" --target selftest \
  test_suite_x509parse test_suite_x509write test_suite_pkcs7 test_suite_ssl \
  test_suite_asn1parse test_suite_base64 test_suite_pem test_suite_pk test_suite_pkparse \
  test_suite_sha256 test_suite_sha512 test_suite_md test_suite_rsa test_suite_ecp
