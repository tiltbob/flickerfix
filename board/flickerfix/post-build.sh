#!/bin/sh
# Runs after the root filesystem is assembled, before it is packed into the
# kernel's initramfs.
set -eu
TARGET_DIR=$1

echo "${FLICKERFIX_VARIANT:-baseline}" > "$TARGET_DIR/etc/flickerfix-variant"

# Nothing in this image uses the network, and no log daemon should compete
# with the test for the kernel log.
for s in S40network S01syslogd S02klogd S50crond; do
	rm -f "$TARGET_DIR/etc/init.d/$s"
done
