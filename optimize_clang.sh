#!/bin/bash

# Build and compare Clang with DeduBB, Propeller's code layout and LLVM's
# MachineOutliner: binary sizes, and the time each compiler takes to build Clang.
# Run from the DeduBB repository root. Outputs: clang_dedubb_binaries/.

set -eux

# Set to 0 to disable an option. Call-Return folds also occur in subsequence mode.
DEDUBB_SIZE_OPT=${DEDUBB_SIZE_OPT:-1}
DEDUBB_CALL_RETURN=${DEDUBB_CALL_RETURN:-1}
DEDUBB_SUBSEQUENCE=${DEDUBB_SUBSEQUENCE:-1}
DEDUBB_OUTLINER=${DEDUBB_OUTLINER:-1}
# Timed Clang builds per compiler (perf stat -r).
DEDUBB_PERF_RUNS=${DEDUBB_PERF_RUNS:-1}

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

# Keep .text.dedubb and other .text.* output sections separate. A build ID
# lets perf profiles be matched to the binary.
LD_FLAGS="-fuse-ld=lld -Wl,--build-id -Wl,--lto-basic-block-address-map -Wl,-z,keep-text-section-prefix ${SIZE_LDFLAGS}"
INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS=(
  "-DCMAKE_C_FLAGS=-funique-internal-linkage-names -fbasic-block-address-map ${SIZE_CFLAGS}"
  "-DCMAKE_CXX_FLAGS=-funique-internal-linkage-names -fbasic-block-address-map ${SIZE_CFLAGS}"
  "-DCMAKE_EXE_LINKER_FLAGS=${LD_FLAGS}"
  "-DCMAKE_SHARED_LINKER_FLAGS=${LD_FLAGS}"
  "-DCMAKE_MODULE_LINKER_FLAGS=${LD_FLAGS}" )

# Build Clang in directory $1 with the common flags and those that follow.
build_clang() {
  mkdir -p "$1" && cd "$1"
  cmake -G Ninja \
    "${COMMON_CMAKE_FLAGS[@]}" \
    "${@:2}" \
    ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
  ninja clang
}

PATH_TO_BBADDRMAP_CLANG_BUILD=${BASE_DIR}/bbaddrmap_clang_build
build_clang ${PATH_TO_BBADDRMAP_CLANG_BUILD} "${INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}"
BASELINE=${PATH_TO_BBADDRMAP_CLANG_BUILD}/bin/clang-${CLANG_VERSION}

# 6. Profile the baseline
# As Propeller does: a Clang build whose compiler is a symlink, so any compiler
# can be swapped in, and 100 of its compile commands under perf.
BENCHMARKING_CLANG_BUILD=${BASE_DIR}/benchmarking_clang_build
use_compiler() {
  ln -sf "$1" ${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary/clang
  ln -sf "$1" ${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary/clang++
}
mkdir -p ${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary
use_compiler ${BASELINE}
cd ${BENCHMARKING_CLANG_BUILD}
cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DCMAKE_C_COMPILER=${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary/clang \
  -DCMAKE_CXX_COMPILER=${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary/clang++ \
  ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
ninja clean
ninja -t commands | head -100 >& ./perf_commands.sh
chmod +x ./perf_commands.sh
perf record -e cycles:u -j any,u -o ${PATH_TO_PROFILES}/perf.data -- ./perf_commands.sh
ls -l ${PATH_TO_PROFILES}/perf.data

# 7. Generate DeduBB directives and code layout profiles
# Aliased functions are skipped by default to preserve linker ICF.
DEDUBB_FLAGS=()
if [[ "${DEDUBB_CALL_RETURN}" == 1 ]]; then
  DEDUBB_FLAGS+=("--dedubb_call_return")
fi
if [[ "${DEDUBB_SUBSEQUENCE}" == 1 ]]; then
  DEDUBB_FLAGS+=("--dedubb_subsequence")
fi
# All blocks: no profile needed.
/usr/bin/time -v ${PATH_TO_GENERATE_PROFILES} --binary=${BASELINE} \
  --dedubb_profile=${PATH_TO_PROFILES}/dedubb_directives.txt \
  ${DEDUBB_FLAGS[@]+"${DEDUBB_FLAGS[@]}"} \
  2> \
  ${PATH_TO_ALL_RESULTS}/mem_propeller_dedup_conversion.txt
grep "DeduBB" ${PATH_TO_ALL_RESULTS}/mem_propeller_dedup_conversion.txt | sed 's/^.*\] //' > ${PATH_TO_ALL_RESULTS}/dedubb_step1.txt || true

# Cold blocks, those the profile shows not to have run, and the code layout:
# basic block clusters (cc_profile) and function order (ld_profile).
/usr/bin/time -v ${PATH_TO_GENERATE_PROFILES} --binary=${BASELINE} \
  --profile=${PATH_TO_PROFILES}/perf.data \
  --cc_profile=${PATH_TO_PROFILES}/cluster.txt \
  --ld_profile=${PATH_TO_PROFILES}/symorder.txt \
  --dedubb_profile=${PATH_TO_PROFILES}/dedubb_cold_directives.txt \
  --dedubb_cold_only \
  ${DEDUBB_FLAGS[@]+"${DEDUBB_FLAGS[@]}"} \
  2> \
  ${PATH_TO_ALL_RESULTS}/mem_propeller_profile_conversion.txt
grep "DeduBB" ${PATH_TO_ALL_RESULTS}/mem_propeller_profile_conversion.txt | sed 's/^.*\] //' > ${PATH_TO_ALL_RESULTS}/dedubb_cold_step1.txt || true

# 8. Build code layout and DeduBB Clang
# Propeller's code layout alone, and DeduBB, whose directives apply only to the
# Clang executable's link, on all blocks and on cold blocks, each also with the
# code layout.
LAYOUT_LD_FLAGS="-fuse-ld=lld -Wl,--build-id -Wl,--lto-basic-block-sections=${PATH_TO_PROFILES}/cluster.txt -Wl,--symbol-ordering-file=${PATH_TO_PROFILES}/symorder.txt -Wl,--no-warn-symbol-ordering -Wl,-z,keep-text-section-prefix ${SIZE_LDFLAGS}"
OPTIMIZED_PROPELLER_CC_LD_CMAKE_FLAGS=(
  "-DCMAKE_C_FLAGS=-funique-internal-linkage-names -fbasic-block-sections=list=${PATH_TO_PROFILES}/cluster.txt ${SIZE_CFLAGS}"
  "-DCMAKE_CXX_FLAGS=-funique-internal-linkage-names -fbasic-block-sections=list=${PATH_TO_PROFILES}/cluster.txt ${SIZE_CFLAGS}"
  "-DCMAKE_EXE_LINKER_FLAGS=${LAYOUT_LD_FLAGS}"
  "-DCMAKE_SHARED_LINKER_FLAGS=${LAYOUT_LD_FLAGS}"
  "-DCMAKE_MODULE_LINKER_FLAGS=${LAYOUT_LD_FLAGS}" )
ALL_BLOCKS="-DCLANG_DEDUBB_DIRECTIVES=${PATH_TO_PROFILES}/dedubb_directives.txt"
COLD_BLOCKS="-DCLANG_DEDUBB_DIRECTIVES=${PATH_TO_PROFILES}/dedubb_cold_directives.txt"

PATH_TO_OPTIMIZED_PROPELLER_BUILD=${BASE_DIR}/optimized_propeller_build
PATH_TO_OPTIMIZED_DEDUBB_BUILD=${BASE_DIR}/optimized_dedubb_build
PATH_TO_OPTIMIZED_DEDUBB_COLD_BUILD=${BASE_DIR}/optimized_dedubb_cold_build
PATH_TO_OPTIMIZED_DEDUBB_LAYOUT_BUILD=${BASE_DIR}/optimized_dedubb_layout_build
PATH_TO_OPTIMIZED_DEDUBB_COLD_LAYOUT_BUILD=${BASE_DIR}/optimized_dedubb_cold_layout_build
build_clang ${PATH_TO_OPTIMIZED_PROPELLER_BUILD} "${OPTIMIZED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}"
build_clang ${PATH_TO_OPTIMIZED_DEDUBB_BUILD} "${INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}" "${ALL_BLOCKS}"
build_clang ${PATH_TO_OPTIMIZED_DEDUBB_COLD_BUILD} "${INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}" "${COLD_BLOCKS}"
build_clang ${PATH_TO_OPTIMIZED_DEDUBB_LAYOUT_BUILD} "${OPTIMIZED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}" "${ALL_BLOCKS}"
build_clang ${PATH_TO_OPTIMIZED_DEDUBB_COLD_LAYOUT_BUILD} "${OPTIMIZED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}" "${COLD_BLOCKS}"

# 9. Build MachineOutliner comparisons
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
  build_clang ${PATH_TO_OUTLINER_BUILD} "${OUTLINER_CMAKE_FLAGS[@]}"

  # Global outlining RFC: https://github.com/llvm/llvm-project/pull/90933
  outliner_cmake_flags "-Wl,-mllvm,-codegen-data-thinlto-two-rounds"
  build_clang ${PATH_TO_OUTLINER_TWO_ROUNDS_BUILD} "${OUTLINER_CMAKE_FLAGS[@]}"
fi

# 10. Measure sizes
SIZES=${PATH_TO_ALL_RESULTS}/sizes_clang_dedup.txt
LLVM_SIZE=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/llvm-size
report() {
  printf "%s\n" "$1" >> ${SIZES}
  ${LLVM_SIZE} "$2" >> ${SIZES}
  ${LLVM_SIZE} -A "$2" | grep '^\.text' >> ${SIZES}
}
BUILDS=("DeduBB (all basic blocks):${PATH_TO_OPTIMIZED_DEDUBB_BUILD}/bin/clang-${CLANG_VERSION}"
        "DeduBB (cold basic blocks):${PATH_TO_OPTIMIZED_DEDUBB_COLD_BUILD}/bin/clang-${CLANG_VERSION}")
if [[ "${DEDUBB_OUTLINER}" == 1 ]]; then
  BUILDS+=("MachineOutliner:${PATH_TO_OUTLINER_BUILD}/bin/clang-${CLANG_VERSION}"
           "MachineOutliner (two rounds):${PATH_TO_OUTLINER_TWO_ROUNDS_BUILD}/bin/clang-${CLANG_VERSION}")
fi
BUILDS+=("Code layout (Propeller):${PATH_TO_OPTIMIZED_PROPELLER_BUILD}/bin/clang-${CLANG_VERSION}"
         "DeduBB (all basic blocks) + code layout:${PATH_TO_OPTIMIZED_DEDUBB_LAYOUT_BUILD}/bin/clang-${CLANG_VERSION}"
         "DeduBB (cold basic blocks) + code layout:${PATH_TO_OPTIMIZED_DEDUBB_COLD_LAYOUT_BUILD}/bin/clang-${CLANG_VERSION}")

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
printf "\n%-42s %14s %9s %14s %9s %14s %9s\n" "" "code (.text*)" "" "read-only text" "" "stripped file" "" >> ${SIZES}
printf "%-42s %14d %9s %14d %9s %14d %9s\n" "Baseline" ${BASE_DOT_TEXT} "" ${BASE_TEXT} "" ${BASE_STRIPPED} "" >> ${SIZES}
for build in "${BUILDS[@]}"; do
  awk -v name="${build%%:*}" -v d="$(dot_text_of "${build#*:}")" -v t="$(text_of "${build#*:}")" \
      -v s="$(stripped_of "${build#*:}")" -v bd=${BASE_DOT_TEXT} -v bt=${BASE_TEXT} -v bs=${BASE_STRIPPED} \
      'BEGIN { printf "%-42s %14d %+8.2f%% %14d %+8.2f%% %14d %+8.2f%%\n", name, d, 100 * (d - bd) / bd, t, 100 * (t - bt) / bt, s, 100 * (s - bs) / bs }' >> ${SIZES}
done
printf "\n%s\n%s\n%s\n" \
  "code (.text*): all machine code. read-only text: llvm-size's text, the read-only part" \
  "of the loaded program (code, constants, unwind tables). stripped file: the size on" \
  "disk, as ls -l shows it, of the binary after llvm-strip, as a release ships it." >> ${SIZES}

cat ${SIZES}

# 11. Rebuild Clang with each stripped compiler
# Each compiler builds Clang in the benchmarking build of step 6, timed by perf
# stat. This also verifies it: the build must succeed and give the same Clang,
# bit for bit, as the baseline compiler.
VERIFY_DIR=${BASE_DIR}/verify
mkdir -p ${VERIFY_DIR}
build_name() { local dir=${1%/bin/*}; echo ${dir##*/}; }
COMPILERS=("Baseline:${BASELINE}" "${BUILDS[@]}")
for compiler in "${COMPILERS[@]}"; do
  NAME=$(build_name "${compiler#*:}")
  use_compiler "${compiler#*:}.stripped"
  cd ${BENCHMARKING_CLANG_BUILD}
  perf stat -r ${DEDUBB_PERF_RUNS} -e instructions,cycles,L1-icache-misses,iTLB-misses \
    -o ${PATH_TO_ALL_RESULTS}/perf_clang_${NAME}.txt -- bash -c "ninja clean && ninja clang"
  if [[ -f "bin/clang-${CLANG_VERSION}" ]]; then
    cp bin/clang-${CLANG_VERSION} ${VERIFY_DIR}/clang-${CLANG_VERSION}.${NAME}
    echo "Clang is successfully verified: the stripped ${compiler%%:*} compiler rebuilt Clang."
  else
    echo "Clang verification failed: ${compiler%%:*}: the expected binary is missing." >&2
    exit 1
  fi
done

PERF=${PATH_TO_ALL_RESULTS}/perf_clang_dedup.txt
cycles_of() { awk '$2 == "cycles" {gsub(",", "", $1); print $1}' ${PATH_TO_ALL_RESULTS}/perf_clang_$1.txt; }
seconds_of() { awk '/seconds time elapsed/ {print $1}' ${PATH_TO_ALL_RESULTS}/perf_clang_$1.txt; }
BASE_NAME=$(build_name ${BASELINE})
printf "%-42s %18s %9s %13s %9s %11s\n" "" "cycles" "speedup" "wall time (s)" "speedup" "same Clang" > ${PERF}
for compiler in "${COMPILERS[@]}"; do
  NAME=$(build_name "${compiler#*:}")
  SAME=no
  cmp -s ${VERIFY_DIR}/clang-${CLANG_VERSION}.${BASE_NAME} ${VERIFY_DIR}/clang-${CLANG_VERSION}.${NAME} && SAME=yes
  awk -v name="${compiler%%:*}" -v c="$(cycles_of ${NAME})" -v s="$(seconds_of ${NAME})" \
      -v bc="$(cycles_of ${BASE_NAME})" -v bs="$(seconds_of ${BASE_NAME})" -v same=${SAME} \
      'BEGIN { if (c + 0 > 0 && s + 0 > 0 && bc + 0 > 0 && bs + 0 > 0) printf "%-42s %18d %8.3fx %13.1f %8.3fx %11s\n", name, c, bc / c, s, bs / s, same
               else printf "%-42s %18s %9s %13s %9s %11s\n", name, "n/a", "", "n/a", "", same }' >> ${PERF}
done
printf "\n%s\n%s\n%s\n" \
  "Each compiler, stripped, built Clang (ninja clang, Release, X86) after ninja clean." \
  "speedup: baseline / compiler, above 1 is faster. same Clang: the Clang it built is" \
  "identical to the one the baseline compiler built. perf_clang_*.txt: all counters." >> ${PERF}

cat ${PERF}
if grep -q " no$" ${PERF}; then
  echo "Clang verification failed: a compiler built a different Clang than the baseline." >&2
  exit 1
fi
