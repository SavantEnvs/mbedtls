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

# Fuzz harnesses: <name>:<build dir of the cmake target, relative to build-fuzz>
HARNESSES="fuzz_client fuzz_dtlsclient fuzz_dtlsserver fuzz_server fuzz_x509crl fuzz_x509crt fuzz_x509csr fuzz_pkcs7"
TFPSA_HARNESSES="fuzz_privkey fuzz_pubkey"

new_build_dir() {
  # Always configure from scratch: CMake discards a reused cache when it sees the compiler by name vs its
  # resolved path, and the reconfigured tree then fails to link (unresolved builtin-key hook).
  rm -rf "$1"
  mkdir -p "$1"
  printf '*\n' > "$1/.gitignore"   # keep the whole build dir out of git status; `git clean -X` removes it
}

# 1) Sanitized build of the project (default config plus a deterministic clock, as OSS-Fuzz builds it; the
#    `full` config enables a platform NV-seed entropy source that psa_crypto_init() cannot use here, so
#    every harness would bail out before parsing) including the fuzz programs. The fuzz programs link tests/ helper objects too.
#    -fsanitize=fuzzer-no-link adds SanCov to the library itself (the engine only instruments the harness).
new_build_dir build-fuzz
cmake -S . -B build-fuzz \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
  -DMBEDTLS_FATAL_WARNINGS=OFF -DTF_PSA_CRYPTO_FATAL_WARNINGS=OFF \
  -DENABLE_PROGRAMS=ON -DENABLE_TESTING=OFF \
  -DMBEDTLS_CONFIG_SET="MBEDTLS_PLATFORM_TIME_ALT"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target $HARNESSES $TFPSA_HARNESSES

# 1b) Four upstream harnesses are broken in this tree (see the header of each file in mayhem/harness/); build
#     the fixed copies with the exact flags CMake used and overwrite the harness object, so the relink below
#     picks them up through CMake's own link command.
rebuild_harness() { # <name> <dir containing CMakeFiles/<name>.dir>
  local name="$1" dir="$2" fl
  fl="$dir/CMakeFiles/$name.dir/flags.make"
  local defs incs flags
  defs="$(sed -n 's/^C_DEFINES = //p' "$fl")"
  incs="$(sed -n 's/^C_INCLUDES = //p' "$fl")"
  flags="$(sed -n 's/^C_FLAGS = //p' "$fl")"
  eval "$CC $defs $incs -I$SRC/tf-psa-crypto/programs/fuzz $flags -c mayhem/harness/$name.c -o $dir/CMakeFiles/$name.dir/$name.c.o"
}
for h in fuzz_client fuzz_dtlsclient; do rebuild_harness "$h" build-fuzz/programs/fuzz; done
for h in fuzz_privkey fuzz_pubkey;    do rebuild_harness "$h" build-fuzz/tf-psa-crypto/programs/fuzz; done

# 2) LeakSanitizer off-switch object (ASan + UBSan stay on and halting).
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o

# 3) Relink each harness twice from CMake's own link command: the stock result uses the project's
#    file-input driver (fuzz_onefile.c) -> `<name>-standalone`; swapping that driver for libFuzzer
#    -> `<name>`.
relink() { # <name> <dir containing CMakeFiles/<name>.dir/link.txt>
  local name="$1" dir="$2" link
  link="$(cat "$dir/CMakeFiles/$name.dir/link.txt")"
  ( cd "$dir"
    eval "${link//-o $name/-o $SRC/$name-standalone} $SRC/build-fuzz/lsan_off.o"
    link="${link//\"CMakeFiles\/$name.dir\/__\/__\/tf-psa-crypto\/programs\/fuzz\/fuzz_onefile.c.o\"/}"
    link="${link//CMakeFiles\/$name.dir\/fuzz_onefile.c.o/}"
    eval "${link//-o $name/-o $SRC/$name $LIB_FUZZING_ENGINE} $SRC/build-fuzz/lsan_off.o" )
}
for h in $HARNESSES;       do relink "$h" "build-fuzz/programs/fuzz"; done
for h in $TFPSA_HARNESSES; do relink "$h" "build-fuzz/tf-psa-crypto/programs/fuzz"; done

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
