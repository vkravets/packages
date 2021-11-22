BOARD ?= rpi2
ARCH ?= arm

# =====
_REPO_NAME ?= pikvm
_REPO_KEY ?= 912C773ABBD1B584
_REPO_DEST ?= root@pikvm.org:/var/www/
_PIBUILDER_REPO ?= https://github.com/pikvm/pi-builder

_ALARM_UID := $(shell id -u)
_ALARM_GID := $(shell id -g)
_BUILDENV_IMAGE = pikvm/packages-buildenv-$(BOARD)-$(ARCH)
_BUILDENV_DIR = ./.pi-builder/$(BOARD)-$(ARCH)
_BUILD_DIR = ./.build/$(BOARD)-$(ARCH)
_REPO_DIR = ./repos/$(BOARD)-$(ARCH)
_CACHE_DIR = ./.cache/$(BOARD)-$(ARCH)
_MAKE_J = 12

_UPDATABLE_PACKAGES := $(sort $(subst /update.mk,,$(subst packages/,,$(wildcard packages/*/update.mk))))
_KNOWN_BOARDS := $(sort $(subst order.$(ARCH)., ,$(wildcard packages/order.$(ARCH).*)))


# =====
_NULL :=
_SPACE := $(_NULL) $(_NULL)

define join_spaced
$(subst $(_SPACE),|,$1)
endef

define optbool
$(filter $(shell echo $(1) | tr A-Z a-z),yes on 1)
endef

define say
@ tput bold
@ tput setaf 2
@ echo "===== $1 ====="
@ tput sgr0
endef

define die
@ tput bold
@ tput setaf 1
@ echo "===== $1 ====="
@ tput sgr0
@ exit 1
endef


# =====
all:
	@ echo "Available commands:"
	@ echo "    make binfmt BOARD=<$(call join_spaced,$(_KNOWN_BOARDS))>"
	@ echo "    make shell BOARD=<$(call join_spaced,$(_KNOWN_BOARDS))>"
	@ echo "    make buildenv BOARD=<$(call join_spaced,$(_KNOWN_BOARDS))> NC=<1|0>"
	@ echo "    make pushenv BOARD=<$(call join_spaced,$(_KNOWN_BOARDS))>"
	@ echo "    make pullenv BOARD=<$(call join_spaced,$(_KNOWN_BOARDS))>"
	@ echo
	@ echo "    make update"
	@ for target in $(_UPDATABLE_PACKAGES); do echo "    make update-$$target"; done
	@ echo
	@ for board in $(_KNOWN_BOARDS); do echo "    make packages-$$board"; done
	@ echo
	@ for board in $(_KNOWN_BOARDS); do echo "    make buildenv-$$board NC=<1|0>"; done
	@ echo
	@ for board in $(_KNOWN_BOARDS); do echo "    make pushenv-$$board"; done
	@ echo
	@ for board in $(_KNOWN_BOARDS); do echo "    make pullenv-$$board"; done
	@ echo
	@ echo "    make upload"


upload:
	rsync -rl --progress --delete $(_BASE_REPOS_DIR)/ root@files.pikvm.org:/var/www/files.pikvm.org/repos/arch


download:
	rm -rf $(_BASE_REPOS_DIR)
	rsync -rl --progress root@files.pikvm.org:/var/www/files.pikvm.org/repos/arch/ $(_BASE_REPOS_DIR)


define make_update_package_target
update-$1:
	$(MAKE) -C packages/$1 -f update.mk update BOARD=$(BOARD) ARCH=$(ARCH)
endef
$(foreach pkg,$(_UPDATABLE_PACKAGES),$(eval $(call make_update_package_target,$(pkg))))
update: $(addprefix update-,$(_UPDATABLE_PACKAGES))


define make_board_target
packages-$1:
	$(MAKE) binfmt BOARD=$1
	for pkg in `cat packages/order.$(ARCH).$1`; do \
		$(MAKE) _build BOARD=$1 PKG=$$$$pkg NOINT=$$$$NOINT J=$$$$J || exit 1; \
	done
buildenv-$1:
	$(MAKE) buildenv BOARD=$1 NC=$$(NC)
pushenv-$1:
	$(MAKE) pushenv BOARD=$1
pullenv-$1:
	$(MAKE) pullenv BOARD=$1
endef
$(foreach board,$(_KNOWN_BOARDS),$(eval $(call make_board_target,$(board))))


_build:
	$(call say,"Ensuring package $(PKG) for $(BOARD)")
	rm -rf $(_BUILD_DIR)
	$(MAKE) _run \
		_MAKE_J=$(if $(J),$(J),$(_MAKE_J)) \
		BOARD=$(BOARD) \
		OPTS="--tty $(if $(call optbool,$(NOINT)),,--interactive)" \
		CMD="/tools/buildpkg $(PKG) '$(call optbool,$(FORCE))' '$(call optbool,$(NOREPO))'"
	$(call say,"Complete package $(PKG) for $(BOARD)")


shell:
	$(MAKE) _run \
		_MAKE_J=$(if $(J),$(J),$(_MAKE_J)) \
		BOARD=$(BOARD) \
		OPTS="--tty --interactive" \
		CMD=/bin/bash


binfmt: buildenv
	$(MAKE) -C $(_BUILDENV_DIR) binfmt


buildenv: $(_BUILDENV_DIR)
	$(call say,"Ensuring $(BOARD)-$(ARCH) buildenv")
	$(MAKE) -C $(_BUILDENV_DIR) binfmt
	rm -rf $(_BUILDENV_DIR)/stages/buildenv
	cp -a buildenv $(_BUILDENV_DIR)/stages/buildenv
	$(MAKE) -C $(_BUILDENV_DIR) os \
		NC=$(NC) \
		PASS_ENSURE_TOOLBOX=1 \
		PASS_ENSURE_BINFMT=1 \
		BUILD_OPTS=" \
			--build-arg REPO_NAME=$(_REPO_NAME) \
			--build-arg REPO_KEY=$(_REPO_KEY) \
			--build-arg ALARM_UID=$(_ALARM_UID) \
			--build-arg ALARM_GID=$(_ALARM_GID) \
			--tag $(_BUILDENV_IMAGE) \
		" \
		PROJECT=pikvm-packages \
		BOARD=$(BOARD) \
		ARCH=$(ARCH) \
		STAGES="__init__ buildenv" \
		HOSTNAME=buildenv
	$(call say,"Buildenv $(BOARD)-$(ARCH) is ready")


pushenv:
	docker push $(_BUILDENV_IMAGE)


pullenv:
	docker pull $(_BUILDENV_IMAGE)


# =====
_run: $(_BUILD_DIR) $(_REPO_DIR)
	$(if $(patsubst 1000,,$(shell id -u)),$(call die,"Only user with UID=1000 can build packages"),)
	docker run \
			--rm \
			--tty \
			--interactive \
			--privileged \
			--volume `pwd`/$(_REPO_DIR):/repo:rw \
			--volume `pwd`/$(_BUILD_DIR):/build:rw \
			--volume `pwd`/$(_CACHE_DIR):/cache:rw \
			--volume `pwd`/packages:/packages:ro \
			--env REPO_DIR=/repo \
			--env BUILD_DIR=/build \
			--env PACKAGES_DIR=/packages \
			--env MAKE_J=$(_MAKE_J) \
            --env CCACHE_DIR=/cache \
			--volume $$HOME/.gnupg/:/home/alarm/.gnupg/:rw \
			--volume /run/user/$(_ALARM_UID)/gnupg:/run/user/$(_ALARM_UID)/gnupg:rw \
			$(OPTS) \
		$(_BUILDENV_IMAGE) \
		$(if $(CMD),$(CMD),/bin/bash)


$(_BUILDENV_DIR):
	git clone --depth=1 $(_PIBUILDER_REPO) $(_BUILDENV_DIR)


$(_BUILD_DIR):
	mkdir -p $(_BUILD_DIR)


$(_BASE_REPOS_DIR)/rpi:
	mkdir -p $(_BASE_REPOS_DIR)/rpi
	ln -sf rpi $(_BASE_REPOS_DIR)/zerow
	ln -sf rpi $(_BASE_REPOS_DIR)/rpi-arm


$(_BASE_REPOS_DIR)/rpi2:
	mkdir -p $(_BASE_REPOS_DIR)/rpi2
	ln -sf rpi2 $(_BASE_REPOS_DIR)/zero2w
	ln -sf rpi2 $(_BASE_REPOS_DIR)/rpi3
	ln -sf rpi2 $(_BASE_REPOS_DIR)/rpi2-arm
	ln -sf rpi2 $(_BASE_REPOS_DIR)/rpi3-arm
	ln -sf rpi2 $(_BASE_REPOS_DIR)/rpi4
	ln -sf rpi2 $(_BASE_REPOS_DIR)/rpi4-arm

$(_CACHE_DIR):
	mkdir -p $(_CACHE_DIR)

.PHONY: buildenv packages repos
