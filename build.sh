#!/usr/bin/env bash
# shellcheck disable=SC2164

# Constants
WORKDIR="$(pwd)"
KVER="5.10"
USER="nathan"
HOST="nx"
TIMEZONE="Asia/Jakarta"
ANYKERNEL_REPO="https://github.com/MillenniumOSS/AnyKernel3.git"
ANYKERNEL_BRANCH="mahiru5.10"
KERNEL_DEFCONFIG="gki_defconfig"
KERNEL_REPO="https://github.com/imnathanzero/android_kernel_common_android12-5.10-millennium"
KERNEL_BRANCH="yuuka-lxc"

CLANG_URL="https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b/archive/refs/heads/lineage-20.0.tar.gz"
AK3_ZIP_NAME="$KERNEL_NAME-$KVER-$VARIANT-$BUILD_DATE.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"

# Handle error
exec > >(tee "$WORKDIR/build.log") 2>&1
trap 'error "Failed at line $LINENO [$BASH_COMMAND]"' ERR

# Import functions
source "$WORKDIR/functions.sh"

# Timezone
sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

# Clone kernel source
log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 "$KERNEL_REPO" -b "$KERNEL_BRANCH" "$KSRC"

cd "$KSRC"
LINUX_VERSION=$(make kernelversion)
LINUX_VERSION_CODE=${LINUX_VERSION//./}
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
cd "$WORKDIR"

# Download Clang
CLANG_DIR="$WORKDIR/clang"
CLANG_BIN="${CLANG_DIR}/bin"
if [[ -z "$CLANG_BRANCH" ]]; then
  log "🔽 Downloading Clang..."
  wget -qO clang-archive "$CLANG_URL"
  mkdir -p "$CLANG_DIR"
  case "$(basename $CLANG_URL)" in
    *.tar.* | *.tgz)
      tar -xf clang-archive -C "$CLANG_DIR"
      ;;
    *.7z)
      7z x clang-archive -o"${CLANG_DIR}/" -bd -y > /dev/null
      ;;
    *)
      error "Unsupported file format"
      ;;
  esac
  rm clang-archive

  if [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]] \
    && [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 0 ]]; then
    SINGLE_DIR=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv "$SINGLE_DIR"/* "$CLANG_DIR"/
    rm -rf "$SINGLE_DIR"
  fi
else
  log "🔽 Cloning Clang..."
  git clone --depth=1 "$CLANG_URL" -b "$CLANG_BRANCH" "$CLANG_DIR"
fi

# Clone GNU Assembler
log "Cloning GNU Assembler..."
GAS_DIR="$WORKDIR/gas"
git clone --depth=1 \
  https://android.googlesource.com/platform/prebuilts/gas/linux-x86 \
  -b main \
  "$GAS_DIR"

export PATH="${CLANG_BIN}:${GAS_DIR}:$PATH"

# Extract clang version
COMPILER_STRING=$(clang --version | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

cd "$KSRC"

## KernelSU setup
if ksu_included; then
# Remove existing KernelSU drivers
  for KSU_PATH in drivers/staging/kernelsu drivers/kernelsu KernelSU KernelSU-Next; do
    if [[ -d $KSU_PATH ]]; then
      log "KernelSU driver found in $KSU_PATH, Removing..."
      KSU_DIR=$(dirname "$KSU_PATH")

      [[ -f "$KSU_DIR/Kconfig" ]] && sed -i '/kernelsu/d' "$KSU_DIR/Kconfig"
      [[ -f "$KSU_DIR/Makefile" ]] && sed -i '/kernelsu/d' "$KSU_DIR/Makefile"

      rm -rf $KSU_PATH
    fi
  done

  install_ksu 'KOWX712/KernelSU' 'master'
  config --enable CONFIG_KSU
fi

# i want LTO Thin
config --enable CONFIG_LTO
config --enable CONFIG_LTO_CLANG
config --enable CONFIG_LTO_CLANG_THIN
config --disable CONFIG_LTO_NONE
config --disable CONFIG_LTO_CLANG_FULL

# Declare needed variables
export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
KBUILD_BUILD_TIMESTAMP=$(date)
export KBUILD_BUILD_TIMESTAMP
export KCFLAGS="-w"
MAKE_ARGS=(
  LLVM=1
  LLVM_IAS=1
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  "-j$(nproc --all)"
  "O=$OUTDIR"
)

KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"
MODULE_SYMVERS="$OUTDIR/Module.symvers"
KMI_CHECK="$WORKDIR/py/kmi-check-5.x.py"

text=$(
  cat << EOF
*Kernel Version*: \`${LINUX_VERSION}\`
*Build Date*: \`${KBUILD_BUILD_TIMESTAMP}\`
*Variant*: \`${VARIANT}\`
*Compiler*: \`${COMPILER_STRING}\`
EOF
)

## Build GKI
log "Generating config..."
make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"

## idk?
make "${MAKE_ARGS[@]}" olddefconfig

# Build the actual kernel
log "Building kernel..."
make "${MAKE_ARGS[@]}"

# Check KMI Function symbol
$KMI_CHECK "$KSRC/android/abi_gki_aarch64.xml" "$MODULE_SYMVERS" || true

## Post-compiling stuff
cd "$WORKDIR"

# Clone AnyKernel
log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel

# Zip the anykernel
cd anykernel
log "Zipping anykernel..."
cp "$KERNEL_IMAGE" .
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./*
cd "$OLDPWD"

if [[ $STATUS != "BETA" ]]; then
  echo "BASE_NAME=$KERNEL_NAME" >> "$GITHUB_ENV"
  mkdir -p "$WORKDIR/artifacts"
  mv "$WORKDIR"/*.zip "$WORKDIR/artifacts"
fi

if [[ $LAST_BUILD == "true" ]] && [[ $STATUS != "BETA" ]]; then
  (
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "KERNEL_NAME=$KERNEL_NAME"
    echo "KVER=$KVER"
  ) >> "$WORKDIR/artifacts/info.txt"
fi

if [[ $STATUS == "BETA" ]]; then
  upload_file "$WORKDIR/$AK3_ZIP_NAME" "$text"
  upload_file "$WORKDIR/build.log"
else
  send_msg "✅ Build Succeeded."
fi

exit 0
