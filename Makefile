# Wrapper around Buildroot. Builds one EFI binary per variant:
#
#   make            both variants
#   make patched    kernel with the fix applied   -> flickerfix-patched.efi
#   make baseline   the same without the fix     -> flickerfix-baseline.efi
#
# Both variants come out of one Buildroot output directory. The userland
# (toolchain, BusyBox, firmware, the root filesystem) is built once; only
# the kernel is built per variant, and the compiler cache makes the second
# kernel build cheap.
#
BUILDROOT_VERSION ?= 2026.08.1
BUILDROOT_URL     ?= https://gitlab.com/buildroot.org/buildroot.git
BUILDROOT_DIR     ?= $(CURDIR)/buildroot
DL_DIR            ?= $(CURDIR)/dl
# Compiler cache, shared by both variants.
CCACHE_DIR        ?= $(CURDIR)/ccache
OUTPUT_DIR        := $(CURDIR)/output

VARIANTS := baseline patched

# Only the patched variant gets the kernel patches.
PATCHES_patched  := $(CURDIR)/patches/linux
PATCHES_baseline :=

# Which variant's kernel is currently built in the output directory.
KERNEL_STAMP := $(OUTPUT_DIR)/.kernel-variant

.PHONY: all both $(VARIANTS) clean
all: both
both: $(VARIANTS)
# One output directory: never build the two variants at the same time.
.NOTPARALLEL:

$(BUILDROOT_DIR)/Makefile:
	git clone --depth 1 -b $(BUILDROOT_VERSION) $(BUILDROOT_URL) $(BUILDROOT_DIR)

BR = $(MAKE) -C $(BUILDROOT_DIR) O=$(OUTPUT_DIR) BR2_EXTERNAL=$(CURDIR) \
	BR2_DL_DIR=$(DL_DIR) BR2_CCACHE_DIR=$(CCACHE_DIR) FLICKERFIX_VARIANT=$@ \
	FLICKERFIX_LINUX_PATCHES=$(PATCHES_$@)

$(VARIANTS): $(BUILDROOT_DIR)/Makefile
	$(BR) flickerfix_defconfig
	@# Throw away the other variant's kernel, keep everything else.
	if [ -f $(KERNEL_STAMP) ] && [ "$$(cat $(KERNEL_STAMP))" != $@ ]; then \
		$(BR) linux-dirclean; \
	fi
	echo $@ > $(KERNEL_STAMP)
	$(BR)
	cp $(OUTPUT_DIR)/images/flickerfix.efi flickerfix-$@.efi
	@echo
	@echo "EFI binary ready: flickerfix-$@.efi"

clean:
	rm -rf output flickerfix-*.efi
