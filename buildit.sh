#!/bin/sh
set -e -x

die() {
    echo "Error: $1" >&2
    exit 1
}

[ -f "NASA_ACQ.xpr" ] \
|| die "Must run in git checkout containing NASA_ACQ.xpr"

[ -f "Workspace/NASA_ACQ/src/nasaAcq.json" ] \
|| die "Must checkout sub-module at: Workspace/NASA_ACQ"

ROOT="$(pwd)"
COMMIT_DATE="$(git log -n1 --format=format:%cd HEAD --date=format:%Y%m%d)"
COMMIT_HASH="$(git log -n1 --format=format:%h HEAD)"
BUILD_TSTAMP="$(date -u +%H%M%S)"

# Scratch space for generated Tcl script fragments AND a private Vitis
# workspace. Using a fresh, unique workspace per build (instead of the
# shared, persistent "Workspace" directory) avoids project-state collisions
# left over from a previous run, and the same trap that cleans up the Tcl
# fragments also removes the Vitis workspace automatically.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' INT QUIT EXIT
VITIS_WS="$SCRATCH/vitis_ws"
mkdir -p "$VITIS_WS"

# Absolute paths for everything handed between Vivado, Vitis, and updatemem,
# so each tool's own working-directory assumptions can't cause it to read or
# write the wrong file.
XSA_PATH="$ROOT/NASA_ACQ.xsa"
ELF_PATH="$VITIS_WS/bar/Release/bar.elf"
MMI_PATH="$ROOT/NASA_ACQ.runs/impl_1/NASA_ACQ.mmi"
RAW_BIT_PATH="$ROOT/NASA_ACQ.runs/impl_1/NASA_ACQ.bit"
OUT_BIT_PATH="$ROOT/quartzV1-$COMMIT_DATE-$BUILD_TSTAMP-$COMMIT_HASH.bit"

# Run code generators
( cd Workspace/NASA_ACQ/src && sh createVerilogHeader.sh && make)

# vivado: Generate .XSA file

cat <<EOF > "$SCRATCH/xsa.tcl"
open_project "NASA_ACQ.xpr"

validate_ip -verbose [get_ips]

generate_target all [get_files *.bd]
generate_target all [get_files "*/NASA_ACQ.srcs/sources_1/ip/*/*.xci"]

write_hw_platform -minimal -fixed "$XSA_PATH"
EOF

vivado -mode batch -source "$SCRATCH/xsa.tcl"

[ -f "$XSA_PATH" ] \
|| die "Vivado did not produce $XSA_PATH"

# vitis: build ublaze application (.ELF file) in a private, unique workspace

cat <<EOF > "$SCRATCH/platform.tcl"
setws "$VITIS_WS"
platform create -name NASA_ACQ_platform -hw "$XSA_PATH"
domain create -name foo -os standalone -proc microblaze_0
app create -name bar -platform NASA_ACQ_platform -domain foo -template "Empty Application(C)"
importsources -name bar -path "$ROOT/Workspace/NASA_ACQ/src" -linker-script
app config -name bar build-config Release
app build -name bar
EOF

xsct "$SCRATCH/platform.tcl"

[ -f "$ELF_PATH" ] \
|| die "Vitis did not produce $ELF_PATH"

# vivado: generate .BIT file

cat <<EOF > "$SCRATCH/bit.tcl"
open_project "NASA_ACQ.xpr"

reset_run synth_1
reset_run impl_1

# slow part...
launch_runs synth_1 -jobs 2
wait_on_run -verbose synth_1

# zzzz....
launch_runs impl_1 -jobs 2 -to_step write_bitstream
wait_on_run -verbose impl_1

# insert .elf into ublaze BRAM for final .bit
exec updatemem \
 --meminfo "$MMI_PATH" \
 --proc bd_i/microblaze_0 \
 --data "$ELF_PATH" \
 --bit "$RAW_BIT_PATH" \
 --force \
 --out "$OUT_BIT_PATH"

EOF

vivado -mode batch -source "$SCRATCH/bit.tcl"

[ -f "$OUT_BIT_PATH" ] \
|| die "updatemem did not produce $OUT_BIT_PATH"

echo "All done!"

ls -lh "$OUT_BIT_PATH"
sha256sum "$OUT_BIT_PATH"
