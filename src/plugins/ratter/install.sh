#!/bin/bash -eu

make
cp -r ../../../plugins/ratter.so /usr/local/opt/chunkwm/share/chunkwm/plugins/.
chunkc core::load ratter.so
