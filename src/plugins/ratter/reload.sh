#!/bin/bash -eu
brew services reload chunkwm
sleep 1
chunkc core::log_level debug
chunkc core::log_file /tmp/chunkwm.log
