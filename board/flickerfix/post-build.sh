#!/bin/sh
# Runs after the root filesystem is assembled, before it is packed into the
# kernel's initramfs.
set -eu
TARGET_DIR=$1

echo "${FLICKERFIX_VARIANT:-baseline}" > "$TARGET_DIR/etc/flickerfix-variant"

# Nothing in this image uses the network.
rm -f "$TARGET_DIR/etc/init.d/S40network"
