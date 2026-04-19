.PHONY: build-daemon run-daemon build-ui run-ui icon app app-release dmg dmg-release run clean

# ---------- Daemon ----------
build-daemon:
	cd daemon && cargo build

build-daemon-release:
	cd daemon && cargo build --release

run-daemon:
	cd daemon && cargo run

# ---------- UI ----------
build-ui:
	cd ui && swift build

run-ui:
	cd ui && swift run

# ---------- Icon + .app bundle ----------
icon:
	./ui/Scripts/build_icon.sh

app:
	./ui/Scripts/build_app.sh

app-release:
	./ui/Scripts/build_app.sh --release

# ---------- Distributable DMG (drag-to-/Applications) ----------
dmg:
	./ui/Scripts/build_dmg.sh

dmg-release:
	./ui/Scripts/build_dmg.sh --release

# ---------- Convenience ----------
# Build & launch the bundled .app (debug). This is the recommended way
# to run Teleport — the menu-bar icon will appear in the top-right.
run: app
	open ui/Teleport.app

clean:
	rm -rf ui/.build ui/Teleport.app ui/Resources/AppIcon.icns ui/Resources/AppIcon.png dist/
	cd daemon && cargo clean
