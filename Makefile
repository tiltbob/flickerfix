# Wrapper around Buildroot. Builds one EFI binary per variant:
#
#   make            kernel with the fix applied   -> flickerfix-patched.efi
#   make baseline   the same without the fix     -> flickerfix-baseline.efi
#   make both
#
BUILDROOT_VERSION ?= 2026.08.1
BUILDROOT_URL     ?= https://gitlab.com/buildroot.org/buildroot.git
BUILDROOT_DIR     ?= $(CURDIR)/buildroot
DL_DIR            ?= $(CURDIR)/dl
# Compiler cache, shared by both variants.
CCACHE_DIR        ?= $(CURDIR)/ccache

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
	BR2_DL_DIR=$(DL_DIR) BR2_CCACHE_DIR=$(CCACHE_DIR) FLICKERFIX_VARIANT=$@ \
	FLICKERFIX_LINUX_PATCHES=$(PATCHES_$@)

$(VARIANTS): $(BUILDROOT_DIR)/Makefile
	$(BR) flickerfix_defconfig
	$(BR)
	cp output/$@/images/flickerfix.efi flickerfix-$@.efi
	@echo
	@echo "EFI binary ready: flickerfix-$@.efi"

clean:
	rm -rf output flickerfix-*.efi
