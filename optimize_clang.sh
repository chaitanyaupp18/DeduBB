#!/bin/bash

# Build Clang, optimize it with BOLT and with BOLT + DeduBB, and compare them.
# Run from the DeduBB repository root. Outputs: clang_dedubb_binaries/.

set -eux

# Set to 0 to disable an option. DEDUBB_BOLT_FLAGS go to both BOLT runs. The
# default is what --dedubb implies: write the new code where the original
# .text was, if it fits, aligned as it was (64 bytes in Clang); keep the
# program header table in place, which GNU strip handles; and leave functions
# unaligned.
DEDUBB_SIZE_OPT=${DEDUBB_SIZE_OPT:-1}
DEDUBB_PERF_RUNS=${DEDUBB_PERF_RUNS:-1}
DEDUBB_BOLT_FLAGS=${DEDUBB_BOLT_FLAGS:---use-old-text --use-gnu-stack --align-functions=1 --align-text=64}

CWD="$(pwd)"
BASE_DIR=${CWD}/clang_dedubb_binaries
if [[ -d "${BASE_DIR}" ]]; then
    mv ${BASE_DIR} "${CWD}/clang_dedubb_binaries.old"
fi
mkdir -p "${BASE_DIR}"

PATH_TO_LLVM_SOURCES=${BASE_DIR}/sources
PATH_TO_TRUNK_LLVM_BUILD=${BASE_DIR}/trunk_llvm_build
PATH_TO_TRUNK_LLVM_INSTALL=${BASE_DIR}/trunk_llvm_install
PATH_TO_ALL_RESULTS=${BASE_DIR}/Results
mkdir -p ${PATH_TO_ALL_RESULTS}

# 1. Prepare LLVM
mkdir -p ${PATH_TO_LLVM_SOURCES} && cd ${PATH_TO_LLVM_SOURCES}
if [ ! -d "llvm-project" ]; then
    git clone https://github.com/llvm/llvm-project.git
    cd llvm-project
    git reset --hard 333edde4e
    git apply ${CWD}/patches/llvm-project-bolt-dedubb.patch
else
    cd llvm-project
fi

# 2. Build the toolchain, BOLT included
mkdir -p ${PATH_TO_TRUNK_LLVM_BUILD} && cd ${PATH_TO_TRUNK_LLVM_BUILD}
cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_ENABLE_PROJECTS="clang;lld;bolt" \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DLLVM_USE_LINKER=lld \
  -DCMAKE_INSTALL_PREFIX="${PATH_TO_TRUNK_LLVM_INSTALL}" \
  -DLLVM_ENABLE_RTTI=On \
  -DLLVM_INCLUDE_TESTS=Off \
  ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
ninja install
CLANG_VERSION=$(sed -Ene 's!^CLANG_EXECUTABLE_VERSION:STRING=(.*)$!\1!p' ${PATH_TO_TRUNK_LLVM_BUILD}/CMakeCache.txt)
LLVM_BOLT=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/llvm-bolt

# 3. Build the baseline
COMMON_CMAKE_FLAGS=(
  "-DLLVM_OPTIMIZED_TABLEGEN=On"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DLLVM_TARGETS_TO_BUILD=X86"
  "-DLLVM_ENABLE_PROJECTS=clang"
  "-DCMAKE_C_COMPILER=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/clang"
  "-DCMAKE_CXX_COMPILER=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/clang++"
  "-DLLVM_USE_LINKER=lld"
  "-DLLVM_ENABLE_LTO=Thin" )

# Override Release's -O3 with -Oz.
SIZE_CFLAGS=""
SIZE_LDFLAGS=""
if [[ "${DEDUBB_SIZE_OPT}" == 1 ]]; then
  COMMON_CMAKE_FLAGS+=(
    "-DCMAKE_C_FLAGS_RELEASE=-Oz -DNDEBUG"
    "-DCMAKE_CXX_FLAGS_RELEASE=-Oz -DNDEBUG" )
  SIZE_CFLAGS="-ffunction-sections -fdata-sections"
  SIZE_LDFLAGS="-Wl,--gc-sections -Wl,--icf=all"
fi

# BOLT rewrites the code in relocation mode, which needs the link's
# relocations (--emit-relocs).
LD_FLAGS="-fuse-ld=lld -Wl,--emit-relocs ${SIZE_LDFLAGS}"
BASELINE_CC_LD_CMAKE_FLAGS=(
  "-DCMAKE_C_FLAGS=${SIZE_CFLAGS}"
  "-DCMAKE_CXX_FLAGS=${SIZE_CFLAGS}"
  "-DCMAKE_EXE_LINKER_FLAGS=${LD_FLAGS}"
  "-DCMAKE_SHARED_LINKER_FLAGS=${LD_FLAGS}"
  "-DCMAKE_MODULE_LINKER_FLAGS=${LD_FLAGS}" )

PATH_TO_BASELINE_BUILD=${BASE_DIR}/baseline_clang_build
mkdir -p ${PATH_TO_BASELINE_BUILD} && cd ${PATH_TO_BASELINE_BUILD}
cmake -G Ninja \
  "${COMMON_CMAKE_FLAGS[@]}" \
  "${BASELINE_CC_LD_CMAKE_FLAGS[@]}" \
  ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
ninja clang
BASELINE=${PATH_TO_BASELINE_BUILD}/bin/clang-${CLANG_VERSION}

# 4. Optimize Clang with BOLT, without and with DeduBB
# Each output gets the baseline's lib/ for Clang's own headers.
bolt() {
  local dir=$1
  shift
  mkdir -p ${dir}/bin
  ln -sfn ${PATH_TO_BASELINE_BUILD}/lib ${dir}/lib
  /usr/bin/time -v ${LLVM_BOLT} ${BASELINE} -o ${dir}/bin/clang-${CLANG_VERSION} \
    ${DEDUBB_BOLT_FLAGS} "$@" > ${PATH_TO_ALL_RESULTS}/bolt_${dir##*/}.txt 2>&1
}
PATH_TO_BOLT_BUILD=${BASE_DIR}/bolt_build
PATH_TO_DEDUBB_BOLT_BUILD=${BASE_DIR}/dedubb_bolt_build
bolt ${PATH_TO_BOLT_BUILD}
bolt ${PATH_TO_DEDUBB_BOLT_BUILD} --dedubb
grep "DeduBB" ${PATH_TO_ALL_RESULTS}/bolt_dedubb_bolt_build.txt

# 5. Measure sizes
# BOLT writes the new code to .text and, for the DeduBB masters, .text.dedubb.
# What is left of the original code is in .bolt.org.text: nothing, if the new
# code fits where the old was.
SIZES=${PATH_TO_ALL_RESULTS}/sizes_clang_dedup.txt
LLVM_SIZE=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/llvm-size
LLVM_STRIP=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/llvm-strip
BUILDS=("BOLT:${PATH_TO_BOLT_BUILD}/bin/clang-${CLANG_VERSION}"
        "BOLT + DeduBB:${PATH_TO_DEDUBB_BOLT_BUILD}/bin/clang-${CLANG_VERSION}")
report() {
  printf "%s\n" "$1" >> ${SIZES}
  ${LLVM_SIZE} "$2" >> ${SIZES}
  ${LLVM_SIZE} -A "$2" | grep -E '^\.(text|bolt\.org\.text)' >> ${SIZES}
}
: > ${SIZES}
report "Baseline Stats" ${BASELINE}
for build in "${BUILDS[@]}"; do
  printf "\n" >> ${SIZES}
  report "${build%%:*} Stats" "${build#*:}"
done

dot_text_of() { ${LLVM_SIZE} -A "$1" | awk '$1 ~ /^\.text/ {s += $2} END {print s}'; }
stripped_of() { ${LLVM_STRIP} -o "$1.stripped" "$1" && stat -c %s "$1.stripped"; }
BASE_DOT_TEXT=$(dot_text_of ${BASELINE})
BASE_STRIPPED=$(stripped_of ${BASELINE})
printf "\n%-30s %14s %9s %14s %9s\n" "" "code (.text*)" "" "stripped file" "" >> ${SIZES}
printf "%-30s %14d %9s %14d %9s\n" "Baseline" ${BASE_DOT_TEXT} "" ${BASE_STRIPPED} "" >> ${SIZES}
for build in "${BUILDS[@]}"; do
  awk -v name="${build%%:*}" -v d="$(dot_text_of "${build#*:}")" -v s="$(stripped_of "${build#*:}")" \
      -v bd=${BASE_DOT_TEXT} -v bs=${BASE_STRIPPED} \
      'BEGIN { printf "%-30s %14d %+8.2f%% %14d %+8.2f%%\n", name, d, 100 * (d - bd) / bd, s, 100 * (s - bs) / bs }' >> ${SIZES}
done
printf "\n%s\n%s\n%s\n" \
  "code (.text*): the machine code Clang runs, not what BOLT leaves of the" \
  "original in .bolt.org.text. stripped file: the size on disk, as ls -l shows" \
  "it, of the binary after llvm-strip." >> ${SIZES}

cat ${SIZES}

# 6. Rebuild Clang with each stripped compiler
# Each compiler builds Clang, timed by perf stat. This also verifies it: the
# build must succeed and give the same Clang, bit for bit, as the baseline
# compiler.
BENCHMARKING_CLANG_BUILD=${BASE_DIR}/benchmarking_clang_build
VERIFY_DIR=${BASE_DIR}/verify
mkdir -p ${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary ${VERIFY_DIR}
use_compiler() {
  ln -sf "$1" ${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary/clang
  ln -sf "$1" ${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary/clang++
}
use_compiler "${BASELINE}.stripped"
cd ${BENCHMARKING_CLANG_BUILD}
cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DCMAKE_C_COMPILER=${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary/clang \
  -DCMAKE_CXX_COMPILER=${BENCHMARKING_CLANG_BUILD}/symlink_to_clang_binary/clang++ \
  ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm

build_name() { local dir=${1%/bin/*}; echo ${dir##*/}; }
COMPILERS=("Baseline:${BASELINE}" "${BUILDS[@]}")
for compiler in "${COMPILERS[@]}"; do
  NAME=$(build_name "${compiler#*:}")
  use_compiler "${compiler#*:}.stripped"
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
printf "%-30s %18s %9s %13s %9s %11s\n" "" "cycles" "speedup" "wall time (s)" "speedup" "same Clang" > ${PERF}
for compiler in "${COMPILERS[@]}"; do
  NAME=$(build_name "${compiler#*:}")
  SAME=no
  cmp -s ${VERIFY_DIR}/clang-${CLANG_VERSION}.${BASE_NAME} ${VERIFY_DIR}/clang-${CLANG_VERSION}.${NAME} && SAME=yes
  awk -v name="${compiler%%:*}" -v c="$(cycles_of ${NAME})" -v s="$(seconds_of ${NAME})" \
      -v bc="$(cycles_of ${BASE_NAME})" -v bs="$(seconds_of ${BASE_NAME})" -v same=${SAME} \
      'BEGIN { if (c + 0 > 0 && s + 0 > 0 && bc + 0 > 0 && bs + 0 > 0) printf "%-30s %18d %8.3fx %13.1f %8.3fx %11s\n", name, c, bc / c, s, bs / s, same
               else printf "%-30s %18s %9s %13s %9s %11s\n", name, "n/a", "", "n/a", "", same }' >> ${PERF}
done
printf "\n%s\n%s\n%s\n" \
  "Each compiler, stripped, built Clang (ninja clang, Release, X86) after ninja clean." \
  "speedup: baseline / compiler, above 1 is faster. same Clang: the Clang it built is" \
  "identical to the one the baseline compiler built. perf_clang_*.txt: all counters." >> ${PERF}

cat ${PERF}
