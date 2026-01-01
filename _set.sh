#!/bin/bash
cd "$(dirname "$0")" || exit
if [ ! -d build ]; then
mkdir build
fi
cd build
cmake ..
make
