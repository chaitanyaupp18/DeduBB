#!/bin/bash

## Standalone Evaluation Framework for Cross-Module Basic-Block Deduplication (DeduBB)
##
## This script automatically clones LLVM and Propeller, applies the DeduBB patches,
## and compiles a pristine LLVM compiler to evaluate the deduplication savings
## (tail-call folds, one- and two-exit Save-and-Jump folds, and Call-Return folds
## of whole block bodies or of ranges, runs of instructions inside blocks).
##
## Both clang builds (the BBAddrMap baseline and the DeduBB build) are optimized for
## size: -Oz, one section per function and datum, --gc-sections and --icf=all. The
## savings reported are on top of those. Run with DEDUBB_SIZE_OPT=0 to use the plain
## Release (-O3) flags instead, with DEDUBB_SUBSEQUENCE=0 to fold whole block bodies
## only, and with DEDUBB_CALL_RETURN=0 DEDUBB_SUBSEQUENCE=0 to leave out the
## Call-Return folds.
##
## For comparison, it also builds clang with LLVM's MachineOutliner, which -Oz does
## not run on x86-64: once outlining within each ThinLTO module, and once with two
## rounds of code generation (global outlining). Run with DEDUBB_OUTLINER=0 to skip
## those two builds.

set -eux

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

# 1. Clone and Patch LLVM
mkdir -p ${PATH_TO_LLVM_SOURCES} && cd ${PATH_TO_LLVM_SOURCES}
if [ ! -d "llvm-project" ]; then
    git clone https://github.com/llvm/llvm-project.git
    cd llvm-project
    git reset --hard 333edde4e
    git apply ${CWD}/patches/llvm-project-dedubb.patch
else
    cd llvm-project
fi

# 2. Clone and Patch Propeller
cd ${BASE_DIR}
if [ ! -d "propeller" ]; then
    git clone https://github.com/google/llvm-propeller.git propeller
    cd propeller
    git reset --hard e2c7049
    git apply ${CWD}/patches/llvm-propeller-dedubb.patch
else
    cd propeller
fi

# 3. Build Trunk LLVM
mkdir -p ${PATH_TO_TRUNK_LLVM_BUILD} && cd ${PATH_TO_TRUNK_LLVM_BUILD}
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_ENABLE_PROJECTS="clang;lld;compiler-rt" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DLLVM_USE_LINKER=lld -DCMAKE_INSTALL_PREFIX="${PATH_TO_TRUNK_LLVM_INSTALL}" -DLLVM_ENABLE_RTTI=On -DLLVM_INCLUDE_TESTS=Off ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
ninja install
CLANG_VERSION=$(sed -Ene 's!^CLANG_EXECUTABLE_VERSION:STRING=(.*)$!\1!p' ${PATH_TO_TRUNK_LLVM_BUILD}/CMakeCache.txt)

# 4. Build generate_propeller_profiles
cd ${PATH_TO_PROPELLER_SOURCES}
cmake -G Ninja -B build
ninja -C build generate_propeller_profiles
PATH_TO_GENERATE_PROFILES=${PATH_TO_PROPELLER_SOURCES}/build/propeller/generate_propeller_profiles

# 5. Build BBAddrMap Baseline
COMMON_CMAKE_FLAGS=(
  "-DLLVM_OPTIMIZED_TABLEGEN=On"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DLLVM_TARGETS_TO_BUILD=X86"
  "-DLLVM_ENABLE_PROJECTS=clang"
  "-DCMAKE_C_COMPILER=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/clang"
  "-DCMAKE_CXX_COMPILER=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/clang++"
  "-DLLVM_USE_LINKER=lld"
  "-DLLVM_ENABLE_LTO=Thin" )

# Size optimization. The baseline and the DeduBB build must use the same flags,
# since the DeduBB directives name the baseline's basic blocks.
#   -Oz replaces Release's -O3 (the ThinLTO backend in lld honors it too).
#   LLVM's CMake already adds -ffunction-sections -fdata-sections to Release builds;
#   they are repeated here to keep the flag set explicit. clang itself is linked
#   without --gc-sections by default (it keeps symbols for plugins), so it is
#   added, together with identical code folding.
SIZE_CFLAGS=""
SIZE_LDFLAGS=""
if [[ "${DEDUBB_SIZE_OPT}" == 1 ]]; then
  #COMMON_CMAKE_FLAGS+=(
  #  "-DCMAKE_C_FLAGS_RELEASE=-Oz -DNDEBUG"
  #  "-DCMAKE_CXX_FLAGS_RELEASE=-Oz -DNDEBUG" )
  SIZE_CFLAGS="-ffunction-sections -fdata-sections"
  SIZE_LDFLAGS="-Wl,--gc-sections -Wl,--icf=all"
fi

INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS=(
  "-DCMAKE_C_FLAGS=-Oz -funique-internal-linkage-names -fbasic-block-address-map ${SIZE_CFLAGS}"
  "-DCMAKE_CXX_FLAGS=-Oz -funique-internal-linkage-names -fbasic-block-address-map ${SIZE_CFLAGS}"
  "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld -Wl,--lto-basic-block-address-map ${SIZE_LDFLAGS}"
  "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld -Wl,--lto-basic-block-address-map ${SIZE_LDFLAGS}"
  "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld -Wl,--lto-basic-block-address-map ${SIZE_LDFLAGS}" )

PATH_TO_BBADDRMAP_CLANG_BUILD=${BASE_DIR}/bbaddrmap_clang_build
mkdir -p ${PATH_TO_BBADDRMAP_CLANG_BUILD} && cd ${PATH_TO_BBADDRMAP_CLANG_BUILD}
cmake -G Ninja "${COMMON_CMAKE_FLAGS[@]}" "${INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}" ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
ninja clang

# 6. Generate DeduBB Directives
# With --icf=all, functions the linker merged share one address under several names.
# Propeller leaves those alone (--dedubb_skip_aliased_functions, on by default), so
# the DeduBB build does not stop the linker from merging them again.
# --dedubb_call_return adds Call-Return folds: a block's body, calls included, moves
# into one shared routine that every copy calls. Blocks that qualify for both get it
# instead of Save-and-Jump, whose stubs are larger.
# --dedubb_subsequence folds ranges instead of whole bodies: every run of
# instructions that repeats anywhere in the program, with the instructions before
# and after it left in place. Save-and-Jump gets the blocks that hold no range. With
# both flags, the directives are the same as with --dedubb_subsequence alone, and
# the log also shows what whole-body Call-Return would save.
DEDUBB_FLAGS=()
if [[ "${DEDUBB_CALL_RETURN}" == 1 ]]; then
  DEDUBB_FLAGS+=("--dedubb_call_return")
fi
if [[ "${DEDUBB_SUBSEQUENCE}" == 1 ]]; then
  DEDUBB_FLAGS+=("--dedubb_subsequence")
fi
/usr/bin/time -v ${PATH_TO_GENERATE_PROFILES} --binary=${PATH_TO_BBADDRMAP_CLANG_BUILD}/bin/clang-${CLANG_VERSION} --dedubb_profile=${PATH_TO_PROFILES}/dedubb_directives.txt ${DEDUBB_FLAGS[@]+"${DEDUBB_FLAGS[@]}"} 2> ${PATH_TO_ALL_RESULTS}/mem_propeller_dedup_conversion.txt
grep "DeduBB" ${PATH_TO_ALL_RESULTS}/mem_propeller_dedup_conversion.txt | sed 's/^.*\] //' > ${PATH_TO_ALL_RESULTS}/dedubb_step1.txt || true

# 7. Build DeduBB Optimized Clang
# Same flags as the baseline, plus the patch's CLANG_DEDUBB_DIRECTIVES option, which
# applies the directives to the clang executable's link only.
OPTIMIZED_DEDUBB_CC_LD_CMAKE_FLAGS=(
  "${INSTRUMENTED_PROPELLER_CC_LD_CMAKE_FLAGS[@]}"
  "-DCLANG_DEDUBB_DIRECTIVES=${PATH_TO_PROFILES}/dedubb_directives.txt" )

PATH_TO_OPTIMIZED_DEDUBB_BUILD=${BASE_DIR}/optimized_dedubb_build
mkdir -p ${PATH_TO_OPTIMIZED_DEDUBB_BUILD} && cd ${PATH_TO_OPTIMIZED_DEDUBB_BUILD}
cmake -G Ninja "${COMMON_CMAKE_FLAGS[@]}" "${OPTIMIZED_DEDUBB_CC_LD_CMAKE_FLAGS[@]}" ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
ninja clang

# 8. Build MachineOutliner Clangs (for comparison)
# The baseline's flags plus the MachineOutliner. With ThinLTO, code generation runs
# in lld, so the outliner must be enabled at the link: clang's -moutline passes
# -plugin-opt=-enable-machine-outliner to lld (at compile time, it has no effect on
# the bitcode).
#   outliner_build: outlines repeated instruction sequences within each module.
#   outliner_two_rounds_build: -codegen-data-thinlto-two-rounds makes lld run code
#     generation twice. The first round records every sequence it outlines, and the
#     second outlines those sequences in every module (global outlining); --icf=all
#     then merges the identical outlined functions.
# outliner_cmake_flags EXTRA_LDFLAGS: the baseline's compiler and linker flags with
# -moutline, and EXTRA_LDFLAGS added to the linker flags.
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
  cmake -G Ninja "${COMMON_CMAKE_FLAGS[@]}" "${OUTLINER_CMAKE_FLAGS[@]}" ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
  ninja clang

  outliner_cmake_flags "-Wl,-mllvm,-codegen-data-thinlto-two-rounds"
  mkdir -p ${PATH_TO_OUTLINER_TWO_ROUNDS_BUILD} && cd ${PATH_TO_OUTLINER_TWO_ROUNDS_BUILD}
  cmake -G Ninja "${COMMON_CMAKE_FLAGS[@]}" "${OUTLINER_CMAKE_FLAGS[@]}" ${PATH_TO_LLVM_SOURCES}/llvm-project/llvm
  ninja clang
fi

# 9. Measure Sizes
SIZES=${PATH_TO_ALL_RESULTS}/sizes_clang_dedup.txt
LLVM_SIZE=${PATH_TO_TRUNK_LLVM_INSTALL}/bin/llvm-size
# report TITLE BINARY: llvm-size's text, data and bss, and the .text section.
report() {
  printf "%s\n" "$1" >> ${SIZES}
  ${LLVM_SIZE} "$2" >> ${SIZES}
  ${LLVM_SIZE} -A "$2" | grep '^\.text ' >> ${SIZES}
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

# Side by side: .text and llvm-size's text (code, read-only data and unwind tables),
# and their change from the baseline.
text_of() { ${LLVM_SIZE} "$1" | awk 'NR == 2 {print $1}'; }
dot_text_of() { ${LLVM_SIZE} -A "$1" | awk '$1 == ".text" {print $2}'; }
BASE_TEXT=$(text_of ${BASELINE})
BASE_DOT_TEXT=$(dot_text_of ${BASELINE})
printf "\n%-30s %12s %9s %12s %9s\n" "" ".text" "" "text" "" >> ${SIZES}
printf "%-30s %12d %9s %12d %9s\n" "Baseline" ${BASE_DOT_TEXT} "" ${BASE_TEXT} "" >> ${SIZES}
for build in "${BUILDS[@]}"; do
  awk -v name="${build%%:*}" -v d="$(dot_text_of "${build#*:}")" -v t="$(text_of "${build#*:}")" \
      -v bd=${BASE_DOT_TEXT} -v bt=${BASE_TEXT} \
      'BEGIN { printf "%-30s %12d %+8.2f%% %12d %+8.2f%%\n", name, d, 100 * (d - bd) / bd, t, 100 * (t - bt) / bt }' >> ${SIZES}
done

cat ${SIZES}
