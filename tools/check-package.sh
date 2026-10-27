#!/bin/sh
# Check the SD-card package against what the Pocket's firmware is known to
# accept (tools/check_json.py), and that interact.json is the file
# tools/make_interact.py generates. Run by build-local.sh and CI; a fault
# here is one the Pocket would report only as "Error in interact" or
# "General Error" at core load.
set -e
cd "$(dirname "$0")/.."
python3 -I tools/make_interact.py --check
# The sizes are the ones video.json has shipped with and plays correctly at,
# NTSC then PAL; they have not been measured on a bench.
python3 -I tools/check_json.py pkg/pocket --active 596x240 --active 596x288
