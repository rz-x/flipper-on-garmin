#!/usr/bin/env bash
# Build the app for every supported device whose definition files are installed locally.
#
# Device definitions come only from the Connect IQ SDK Manager (GUI, Garmin login), into
# ~/.Garmin/ConnectIQ/Devices/<id>/. This script does not download anything: it adds each TARGET
# that is present to manifest.xml (idempotently) and builds a .prg per device, so "more devices"
# is one GUI download away rather than a manual edit-and-build loop.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Eligible = every installed device whose firmware supports Connect IQ >= 3.2
# (BluetoothLowEnergy) and runs watch apps. Older models are skipped, not failed. Input adapts at
# runtime: buttons on the 5-button family, swipe/tap on touchscreens.
MIN_CIQ="3.2.0"
# The .prg is ~140 KB and the app holds a 1 KB frame plus queues at runtime; devices whose watch-app
# memory limit is 128 KB (fenix 6 non-Pro, Instinct, Venu Sq) compile fine and die on launch.
MIN_MEM_KB=512
mapfile -t TARGETS < <(python3 - "$MIN_CIQ" "$MIN_MEM_KB" "${HOME}/.Garmin/ConnectIQ/Devices" <<'PYEOF'
import json,glob,os,sys
minv=tuple(int(x) for x in sys.argv[1].split('.')); minmem=int(sys.argv[2])*1024
for d in sorted(glob.glob(os.path.join(sys.argv[3],'*','compiler.json'))):
    try: j=json.load(open(d))
    except Exception: continue
    pn=(j.get('partNumbers') or [{}])[0]
    v=tuple(int(x) for x in str(pn.get('connectIQVersion','0')).split('.')[:3])
    wa=[a for a in j.get('appTypes',[]) if a.get('type')=='watchApp']
    if v>=minv and wa and wa[0].get('memoryLimit',0)>=minmem:
        print(os.path.basename(os.path.dirname(d)))
PYEOF
)
DEVDIR="${HOME}/.Garmin/ConnectIQ/Devices"
SDK="${GARMIN_SDK:-${HOME}/garmin-sdk}"
KEY="${CIQ_KEY:-developer_key.der}"

present=()
for t in "${TARGETS[@]}"; do
  [ -d "${DEVDIR}/${t}" ] && present+=("$t")
done
echo "device files present: ${present[*]:-none}"
[ ${#present[@]} -eq 0 ] && { echo "nothing to build - download devices in the SDK Manager"; exit 1; }

# Drop manifest products that are installed locally but no longer eligible (e.g. too little memory).
for t in $(grep -oE 'iq:product id="[^"]+"' manifest.xml | cut -d'"' -f2); do
  if [ -d "${DEVDIR}/${t}" ] && ! printf '%s\n' "${present[@]}" | grep -qx "$t"; then
    sed -i "/iq:product id=\"${t}\"/d" manifest.xml; echo "removed ${t} (not eligible)"
  fi
done

# Add missing <iq:product> lines (keeps existing ones and their order).
for t in "${present[@]}"; do
  grep -q "iq:product id=\"${t}\"" manifest.xml || \
    sed -i "s|    </iq:products>|      <iq:product id=\"${t}\"/>\n    </iq:products>|" manifest.xml
done

mkdir -p bin
fail=0
for t in "${present[@]}"; do
  echo "=== ${t}"
  if "${SDK}/bin/monkeyc" -f monkey.jungle -o "bin/flipper_${t}.prg" -y "${KEY}" -d "${t}" 2>&1 | tail -3; then
    :
  fi
  [ -s "bin/flipper_${t}.prg" ] || { echo "FAILED: ${t}"; fail=1; }
done
exit $fail
