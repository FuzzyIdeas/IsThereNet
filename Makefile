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
ENV=Release
DERIVED_DATA_DIR=$(shell ls -td $$HOME/Library/Developer/Xcode/DerivedData/IsThereNet-* | head -1)

.PHONY: build upload release setversion appcast

print-%  : ; @echo $* = $($*)

build: SHELL=fish
build:
	make-app --build --devid --dmg -s IsThereNet -t IsThereNet -c Release --version $(FULL_VERSION)
	xcp /tmp/apps/IsThereNet-$(FULL_VERSION).dmg Releases/

upload:
	rsync -avzP Releases/*.{delta,dmg} hetzner:/static/lowtechguys/releases/ || true
	rsync -avz Releases/*.html hetzner:/static/lowtechguys/ReleaseNotes/
	rsync -avzP Releases/appcast.xml hetzner:/static/lowtechguys/istherenet/
	cfcli -d lowtechguys.com purge

release:
	gh release create v$(VERSION) -F ReleaseNotes/$(VERSION).md "Releases/IsThereNet-$(VERSION).dmg#IsThereNet.dmg"

appcast: Releases/IsThereNet-$(FULL_VERSION).html
	rm Releases/IsThereNet.dmg || true
ifneq (, $(BETA))
	rm Releases/IsThereNet$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	generate_appcast --channel beta --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/istherenet" --full-release-notes-url "https://github.com/FuzzyIdeas/IsThereNet/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
else
	rm Releases/IsThereNet$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	rm Releases/IsThereNet-*b*.dmg >/dev/null 2>/dev/null || true
	rm Releases/IsThereNet*b*.delta >/dev/null 2>/dev/null || true
	generate_appcast --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/istherenet" --full-release-notes-url "https://github.com/FuzzyIdeas/IsThereNet/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
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
	pandoc -f gfm -o $@ --standalone --metadata title="IsThereNet $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css $(shell ls -t ReleaseNotes/$(VERSION)*.md)
else
	pandoc -f gfm -o $@ --standalone --metadata title="IsThereNet $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css ReleaseNotes/$(VERSION).md
endif
