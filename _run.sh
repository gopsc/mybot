#!/bin/bash
cd "$(dirname "$0")" || exit
bash ./_set.sh
exec ./build/botd
