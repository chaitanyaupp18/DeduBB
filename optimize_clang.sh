#!/bin/bash

# Build and compare Clang with DeduBB and LLVM's MachineOutliner.
# Run from the DeduBB repository root. Outputs: clang_dedubb_binaries/.

set -eux

# Set to 0 to disable an option. Call-Return folds also occur in subsequence mode.
DEDUBB_SIZE_OPT=${DEDUBB_SIZE_OPT:-1}
DEDUBB_CALL_RETURN=${DEDUBB_CALL_RETURN:-1}
DEDUBB_SUBSEQUENCE=${DEDUBB_SUBSEQUENCE:-1}
DEDUBB_OUTLINER=${DEDUBB_OUTLINER:-1}

CWD="$(pwd)"
BASE_DIR=${CWD}/clang_dedubb_binaries
if [[ -d "${BASE_DIR}" ]]; then
    mv ${BASE_DIR} "${CWD}/clang_dedubb_binaries.old"
fi
mkdir -p "${BASE_DIR}"

PATH_TO_LLVM_SOURCES=${BASE_DIR}/sources
PATH_TO_PROPELLER_SOURCES=${BASE_DIR}/propeller
PATH_TO_TRUNK_LLVM_BUILD=${BASE_DIR}/trunk_llvm_build
PATH_TO_TRUNK_LLVM_INSTALL=${BASE_DIR}/trunk_llvm_install
PATH_TO_PROFILES=${BASE_DIR}/Profiles
PATH_TO_ALL_RESULTS=${BASE_DIR}/Results
mkdir -p ${PATH_TO_ALL_RESULTS}
mkdir -p ${PATH_TO_PROFILES}

# 1. Prepare LLVM
mkdir -p ${PATH_TO_LLVM_SOURCES} && cd ${PATH_TO_LLVM_SOURCES}
if [ ! -d "llvm-project" ]; then
    git clone https://github.com/llvm/llvm-project.git
    cd llvm-project
    git reset --hard 333edde4e
    git apply ${CWD}/patches/llvm-project-dedubb.patch
else
    cd llvm-project
fi

# 2. Prepare Propeller
cd ${BASE_DIR}
if [ ! -d "propeller" ]; then
    git clone https://github.com/google/llvm-propeller.git propeller
    cd propeller
    git reset --hard e2c7049
    git apply ${CWD}/patches/llvm-propeller-dedubb.patch
else
    cd propeller
fi

# 3. Build the toolchain
mkdir -p ${PATH_TO_TRUNK_LLVM_BUILD} && cd ${PATH_TO_TRUNK_LLVM_BUILD}
cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_ENABLE_PROJECTS="clang;lld;compiler-rt" \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DLLVM_USE_LINKER=lld \
  -DCMAKE_INSTALL_PREFIX="${PATH_TO_TRUNK_LLVM_INSTALL}" \
  -DLLVM_ENABLE_RTTI=On \
  -DLLVM_INCLUDE_TESTS=Off \
  ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
ninja install
CLANG_VERSION=$(sed -Ene 's!^CLANG_EXECUTABLE_VERSION:STRING=(.*)$!\1!p' ${PATH_TO_TRUNK_LLVM_BUILD}/CMakeCache.txt)

# 4. Build Propeller
cd ${PATH_TO_PROPELLER_SOURCES}
cmake -G Ninja -B build
ninja -C build generate_propeller_profiles
PATH_TO_GENERATE_PROFILES=${PATH_TO_PROPELLER_SOURCES}/build/propeller/generate_propeller_profiles

# 5. Build the baseline
COMMON_CMAKE_FLAGS=(
  "-DLLVM_OPTIMIZED_TABLEGEN=On"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DLLVM_TARGETS_TO_BUILD=X86"
  "-DLLVM_ENABLE_PROJECTS=clang"
  "-DCMAKE_C_COMPILER=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/clang"
  "-DCMAKE_CXX_COMPILER=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/clang++"
  "-DLLVM_USE_LINKER=lld"
  "-DLLVM_ENABLE_LTO=Thin" )

# Use identical baseline flags; override Release's -O3 with -Oz.
SIZE_CFLAGS=""
SIZE_LDFLAGS=""
if [[ "${DEDUBB_SIZE_OPT}" == 1 ]]; then
  COMMON_CMAKE_FLAGS+=(
    "-DCMAKE_C_FLAGS_RELEASE=-Oz -DNDEBUG"
    "-DCMAKE_CXX_FLAGS_RELEASE=-Oz -DNDEBUG" )
  SIZE_CFLAGS="-ffunction-sections -fdata-sections"
  SIZE_LDFLAGS="-Wl,--gc-sections -Wl,--icf=all"
fi

# Keep .text.dedubb and other .text.* output sections separate.
LD_FLAGS="-fuse-ld=lld -Wl,--lto-basic-block-address-map -Wl,-z,keep-text-section-prefix ${SIZE_LDFLAGS}"
INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS=(
  "-DCMAKE_C_FLAGS=-funique-internal-linkage-names -fbasic-block-address-map ${SIZE_CFLAGS}"
  "-DCMAKE_CXX_FLAGS=-funique-internal-linkage-names -fbasic-block-address-map ${SIZE_CFLAGS}"
  "-DCMAKE_EXE_LINKER_FLAGS=${LD_FLAGS}"
  "-DCMAKE_SHARED_LINKER_FLAGS=${LD_FLAGS}"
  "-DCMAKE_MODULE_LINKER_FLAGS=${LD_FLAGS}" )

PATH_TO_BBADDRMAP_CLANG_BUILD=${BASE_DIR}/bbaddrmap_clang_build
mkdir -p ${PATH_TO_BBADDRMAP_CLANG_BUILD} && cd ${PATH_TO_BBADDRMAP_CLANG_BUILD}
cmake -G Ninja \
  "${COMMON_CMAKE_FLAGS[@]}" \
  "${INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}" \
  ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
ninja clang

# 6. Generate DeduBB directives
# Aliased functions are skipped by default to preserve linker ICF.
DEDUBB_FLAGS=()
if [[ "${DEDUBB_CALL_RETURN}" == 1 ]]; then
  DEDUBB_FLAGS+=("--dedubb_call_return")
fi
if [[ "${DEDUBB_SUBSEQUENCE}" == 1 ]]; then
  DEDUBB_FLAGS+=("--dedubb_subsequence")
fi
/usr/bin/time -v ${PATH_TO_GENERATE_PROFILES} --binary=${PATH_TO_BBADDRMAP_CLANG_BUILD}/bin/clang-${CLANG_VERSION} \
  --dedubb_profile=${PATH_TO_PROFILES}/dedubb_directives.txt \
  ${DEDUBB_FLAGS[@]+"${DEDUBB_FLAGS[@]}"} \
  2> \
  ${PATH_TO_ALL_RESULTS}/mem_propeller_dedup_conversion.txt
grep "DeduBB" ${PATH_TO_ALL_RESULTS}/mem_propeller_dedup_conversion.txt | sed 's/^.*\] //' > ${PATH_TO_ALL_RESULTS}/dedubb_step1.txt || true

# 7. Build DeduBB Clang
# Apply directives only to the Clang executable's link.
OPTIMIZED_DEDUBB_CC_LD_CMAKE_FLAGS=(
  "${INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}"
  "-DCLANG_DEDUBB_DIRECTIVES=${PATH_TO_PROFILES}/dedubb_directives.txt" )

PATH_TO_OPTIMIZED_DEDUBB_BUILD=${BASE_DIR}/optimized_dedubb_build
mkdir -p ${PATH_TO_OPTIMIZED_DEDUBB_BUILD} && cd ${PATH_TO_OPTIMIZED_DEDUBB_BUILD}
cmake -G Ninja \
  "${COMMON_CMAKE_FLAGS[@]}" \
  "${OPTIMIZED_DEDUBB_CC_LD_CMAKE_FLAGS[@]}" \
  ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
ninja clang

# 8. Build MachineOutliner comparisons
# Enable outlining at link time for ThinLTO.
outliner_cmake_flags() {
  OUTLINER_CMAKE_FLAGS=()
  local flag
  for flag in "${INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}"; do
    case "${flag}" in
      -DCMAKE_C_FLAGS=*|-DCMAKE_CXX_FLAGS=*) OUTLINER_CMAKE_FLAGS+=("${flag} -moutline") ;;
      *) OUTLINER_CMAKE_FLAGS+=("${flag} -moutline $1") ;;
    esac
  done
}

PATH_TO_OUTLINER_BUILD=${BASE_DIR}/outliner_build
PATH_TO_OUTLINER_TWO_ROUNDS_BUILD=${BASE_DIR}/outliner_two_rounds_build
if [[ "${DEDUBB_OUTLINER}" == 1 ]]; then
  outliner_cmake_flags ""
  mkdir -p ${PATH_TO_OUTLINER_BUILD} && cd ${PATH_TO_OUTLINER_BUILD}
  cmake -G Ninja \
    "${COMMON_CMAKE_FLAGS[@]}" \
    "${OUTLINER_CMAKE_FLAGS[@]}" \
    ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
  ninja clang

  # Global outlining RFC: https://github.com/llvm/llvm-project/pull/90933
  outliner_cmake_flags "-Wl,-mllvm,-codegen-data-thinlto-two-rounds"
  mkdir -p ${PATH_TO_OUTLINER_TWO_ROUNDS_BUILD} && cd ${PATH_TO_OUTLINER_TWO_ROUNDS_BUILD}
  cmake -G Ninja \
    "${COMMON_CMAKE_FLAGS[@]}" \
    "${OUTLINER_CMAKE_FLAGS[@]}" \
    ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
  ninja clang
fi

# 9. Measure sizes
SIZES=${PATH_TO_ALL_RESULTS}/sizes_clang_dedup.txt
LLVM_SIZE=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/llvm-size
report() {
  printf "%s\n" "$1" >> ${SIZES}
  ${LLVM_SIZE} "$2" >> ${SIZES}
  ${LLVM_SIZE} -A "$2" | grep '^\.text' >> ${SIZES}
}
BASELINE=${PATH_TO_BBADDRMAP_CLANG_BUILD}/bin/clang-${CLANG_VERSION}
BUILDS=("DeduBB:${PATH_TO_OPTIMIZED_DEDUBB_BUILD}/bin/clang-${CLANG_VERSION}")
if [[ "${DEDUBB_OUTLINER}" == 1 ]]; then
  BUILDS+=("MachineOutliner:${PATH_TO_OUTLINER_BUILD}/bin/clang-${CLANG_VERSION}"
           "MachineOutliner (two rounds):${PATH_TO_OUTLINER_TWO_ROUNDS_BUILD}/bin/clang-${CLANG_VERSION}")
fi

: > ${SIZES}
report "Baseline BBAddrMap Stats" ${BASELINE}
for build in "${BUILDS[@]}"; do
  printf "\n" >> ${SIZES}
  report "${build%%:*} Stats" "${build#*:}"
done

LLVM_STRIP=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/llvm-strip
text_of() { ${LLVM_SIZE} "$1" | awk 'NR == 2 {print $1}'; }
dot_text_of() { ${LLVM_SIZE} -A "$1" | awk '$1 ~ /^\.text/ {s += $2} END {print s}'; }
stripped_of() { ${LLVM_STRIP} -o "$1.stripped" "$1" && stat -c %s "$1.stripped"; }
BASE_TEXT=$(text_of ${BASELINE})
BASE_DOT_TEXT=$(dot_text_of ${BASELINE})
BASE_STRIPPED=$(stripped_of ${BASELINE})
printf "\n%-30s %14s %9s %14s %9s %14s %9s\n" "" "code (.text*)" "" "read-only text" "" "stripped file" "" >> ${SIZES}
printf "%-30s %14d %9s %14d %9s %14d %9s\n" "Baseline" ${BASE_DOT_TEXT} "" ${BASE_TEXT} "" ${BASE_STRIPPED} "" >> ${SIZES}
for build in "${BUILDS[@]}"; do
  awk -v name="${build%%:*}" -v d="$(dot_text_of "${build#*:}")" -v t="$(text_of "${build#*:}")" \
      -v s="$(stripped_of "${build#*:}")" -v bd=${BASE_DOT_TEXT} -v bt=${BASE_TEXT} -v bs=${BASE_STRIPPED} \
      'BEGIN { printf "%-30s %14d %+8.2f%% %14d %+8.2f%% %14d %+8.2f%%\n", name, d, 100 * (d - bd) / bd, t, 100 * (t - bt) / bt, s, 100 * (s - bs) / bs }' >> ${SIZES}
done
printf "\n%s\n%s\n%s\n" \
  "code (.text*): all machine code. read-only text: llvm-size's text, the read-only part" \
  "of the loaded program (code, constants, unwind tables). stripped file: the size on" \
  "disk, as ls -l shows it, of the binary after llvm-strip, as a release ships it." >> ${SIZES}

cat ${SIZES}

# 10. Rebuild Clang with the stripped DeduBB compiler
VERIFY_DIR="${BASE_DIR}/verify_dedubb"
VERIFY_COMPILER="${PATH_TO_OPTIMIZED_DEDUBB_BUILD}/bin/clang-${CLANG_VERSION}.stripped"

mkdir -p "${VERIFY_DIR}/symlink_clang"
ln -sf "${VERIFY_COMPILER}" "${VERIFY_DIR}/symlink_clang/clang"
ln -sf "${VERIFY_COMPILER}" "${VERIFY_DIR}/symlink_clang/clang++"

cmake -G Ninja \
  -S "${PATH_TO_LLVM_SOURCES}/llvm-project/llvm" \
  -B "${VERIFY_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DCMAKE_C_COMPILER="${VERIFY_DIR}/symlink_clang/clang" \
  -DCMAKE_CXX_COMPILER="${VERIFY_DIR}/symlink_clang/clang++"

ninja -C "${VERIFY_DIR}" clang

if [[ -f "${VERIFY_DIR}/bin/clang-${CLANG_VERSION}" ]]; then
  ls -l "${VERIFY_DIR}/bin/clang-${CLANG_VERSION}"
  echo "Clang is successfully verified: the stripped DeduBB compiler rebuilt Clang."
else
  echo "Clang verification failed: the expected binary is missing." >&2
  exit 1
fi
