# Wrapper around Buildroot. Builds a bootable USB image per variant:
#
#   make            image with the kernel fix applied   -> flickerfix-patched.img
#   make baseline   same image without the fix          -> flickerfix-baseline.img
#   make both
#
BUILDROOT_VERSION ?= 2026.08.1
BUILDROOT_URL     ?= https://gitlab.com/buildroot.org/buildroot.git
BUILDROOT_DIR     ?= $(CURDIR)/buildroot
DL_DIR            ?= $(CURDIR)/dl

VARIANTS := patched baseline

# Only the patched variant gets the kernel patches.
PATCHES_patched  := $(CURDIR)/patches/linux
PATCHES_baseline :=

.PHONY: all both $(VARIANTS) clean
all: patched
both: $(VARIANTS)

$(BUILDROOT_DIR)/Makefile:
	git clone --depth 1 -b $(BUILDROOT_VERSION) $(BUILDROOT_URL) $(BUILDROOT_DIR)

BR = $(MAKE) -C $(BUILDROOT_DIR) O=$(CURDIR)/output/$@ BR2_EXTERNAL=$(CURDIR) \
	BR2_DL_DIR=$(DL_DIR) FLICKERFIX_VARIANT=$@ \
	FLICKERFIX_LINUX_PATCHES=$(PATCHES_$@)

$(VARIANTS): $(BUILDROOT_DIR)/Makefile
	$(BR) flickerfix_defconfig
	$(BR)
	cp output/$@/images/flickerfix.img flickerfix-$@.img
	@echo
	@echo "Image ready: flickerfix-$@.img"

clean:
	rm -rf output flickerfix-*.img
