#!/bin/sh
# The whole product is one EFI binary: bzImage with the EFI stub, the
# initramfs and the command line built in.
set -eu
cp "$BINARIES_DIR/bzImage" "$BINARIES_DIR/flickerfix.efi"
