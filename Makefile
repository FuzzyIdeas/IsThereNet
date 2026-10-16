define n


endef

.EXPORT_ALL_VARIABLES:

BETA=
DELTAS=5

ifeq (, $(VERSION))
VERSION=$(shell rg -o --no-filename 'MARKETING_VERSION = ([^;]+).+' -r '$$1' *.xcodeproj/project.pbxproj | head -1 | sd 'b\d+' '')
endif

ifneq (, $(BETA))
FULL_VERSION:=$(VERSION)b$(BETA)
else
FULL_VERSION:=$(VERSION)
endif

RELEASE_NOTES_FILES := $(wildcard ReleaseNotes/*.md)
# Browsers keep release.css for about 12 days, so pages link it with a hash of the live copy and
# load a new stylesheet as soon as they are rebuilt.
RELEASE_CSS_URL := https://files.lowtechguys.com/release.css
RELEASE_CSS = $(RELEASE_CSS_URL)?v=$(shell curl -fsS $(RELEASE_CSS_URL) | md5 -q | cut -c1-8)
ENV=Release
DERIVED_DATA_DIR=$(shell ls -td $$HOME/Library/Developer/Xcode/DerivedData/IsThereNet-* | head -1)
# Sparkle's generate_appcast ships as an SPM binary artifact, not on PATH. Resolve
# the newest one from the resolved SwiftPM artifacts, falling back to PATH.
GENERATE_APPCAST=$(or $(shell ls -t $$HOME/Library/Developer/Xcode/DerivedData/IsThereNet-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast 2>/dev/null | head -1),generate_appcast)

.PHONY: build upload upload-dmgs upload-deltas upload-notes release setversion appcast

print-%  : ; @echo $* = $($*)

build: SHELL=fish
build:
	make-app --build --devid --dmg -s IsThereNet -c Release --version $(FULL_VERSION)
	xcp /tmp/apps/IsThereNet-$(FULL_VERSION).dmg Releases/

# Each upload opens its own SSH connection instead of joining a shared one, which can be stale
# or busy with forwarded traffic, and gives up when the server stops answering instead of
# hanging. DMGs and deltas are compressed already, so only the text files are compressed.
UPLOAD_SSH=ssh -o ControlMaster=no -o ControlPath=none -o ClearAllForwardings=yes -o Compression=no -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
UPLOAD_RSYNC=rsync -a --partial-dir=.rsync-partial -e "$(UPLOAD_SSH)"

# The DMGs, the deltas and the notes go up in parallel, the appcast last so it never points
# at a file that isn't there yet. IsThereNet.dmg is the same file as the release DMG, so the
# server links it instead of receiving it twice.
upload:
	$(MAKE) -j3 upload-dmgs upload-deltas upload-notes
ifeq (, $(BETA))
	$(UPLOAD_SSH) hetzner 'cd /static/lowtechguys/releases && ln -f IsThereNet-$(VERSION).dmg .IsThereNet.dmg && mv -f .IsThereNet.dmg IsThereNet.dmg'
endif
	$(UPLOAD_RSYNC) -vz Releases/appcast.xml hetzner:/static/lowtechguys/istherenet/
	cfcli -d lowtechguys.com purge

upload-dmgs:
	$(UPLOAD_RSYNC) --progress $(filter-out Releases/IsThereNet.dmg,$(wildcard Releases/*.dmg)) hetzner:/static/lowtechguys/releases/
upload-deltas:
	$(if $(wildcard Releases/*.delta),$(UPLOAD_RSYNC) -v $(wildcard Releases/*.delta) hetzner:/static/lowtechguys/releases/)
upload-notes:
	$(UPLOAD_RSYNC) -vz Releases/*.html hetzner:/static/lowtechguys/ReleaseNotes/

release:
	gh release create v$(VERSION) -F ReleaseNotes/$(VERSION).md "Releases/IsThereNet-$(VERSION).dmg#IsThereNet.dmg"
	git fetch --tags

appcast: Releases/IsThereNet-$(FULL_VERSION).html
	rm Releases/IsThereNet.dmg || true
ifneq (, $(BETA))
	rm Releases/IsThereNet$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	$(GENERATE_APPCAST) --channel beta --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/istherenet" --full-release-notes-url "https://github.com/FuzzyIdeas/IsThereNet/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
else
	rm Releases/IsThereNet$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	rm Releases/IsThereNet-*b*.dmg >/dev/null 2>/dev/null || true
	rm Releases/IsThereNet*b*.delta >/dev/null 2>/dev/null || true
	$(GENERATE_APPCAST) --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/istherenet" --full-release-notes-url "https://github.com/FuzzyIdeas/IsThereNet/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
	cp Releases/IsThereNet-$(FULL_VERSION).dmg Releases/IsThereNet.dmg
endif


setversion: OLD_VERSION=$(shell rg -o --no-filename 'MARKETING_VERSION = ([^;]+).+' -r '$$1' *.xcodeproj/project.pbxproj | head -1)
setversion: SHELL=fish
setversion:
ifneq (, $(FULL_VERSION))
	sdf '((?:CURRENT_PROJECT|MARKETING)_VERSION) = $(OLD_VERSION);' '$$1 = $(FULL_VERSION);'
endif

Releases/IsThereNet-%.html: ReleaseNotes/$(VERSION)*.md
	@echo Compiling $^ to $@
ifneq (, $(BETA))
	pandoc -f gfm --section-divs -o $@ --standalone --metadata title="IsThereNet $(FULL_VERSION) - Release Notes" --css "$(RELEASE_CSS)" $(shell ls -t ReleaseNotes/$(VERSION)*.md)
else
	pandoc -f gfm --section-divs -o $@ --standalone --metadata title="IsThereNet $(FULL_VERSION) - Release Notes" --css "$(RELEASE_CSS)" ReleaseNotes/$(VERSION).md
endif

.PHONY: hooks
hooks:
	@ln -sf "$(CURDIR)/.pre-commit.sh" .git/hooks/pre-commit && echo "pre-commit hook installed -> .pre-commit.sh"
