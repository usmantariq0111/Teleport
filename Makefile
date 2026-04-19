.PHONY: build-daemon run-daemon build-ui run-ui icon app app-release dmg dmg-release run install clean

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

# Replace any installed copy in /Applications with the freshly built
# release bundle. Kills the running app first so the bundle isn't held
# open by Finder/Dock, strips Gatekeeper quarantine attributes, then
# relaunches. Use this every time you change Swift/Rust source — without
# it the previously installed bundle keeps running and you'll keep
# seeing yesterday's UI.
install: app-release
	@echo "▶ Quitting any running Teleport instance…"
	-@osascript -e 'tell application "Teleport" to quit' >/dev/null 2>&1 || true
	-@pkill -x TeleportUI 2>/dev/null || true
	-@pkill -x Teleport 2>/dev/null || true
	-@pkill -x teleport-daemon 2>/dev/null || true
	@sleep 1
	@echo "▶ Removing previous /Applications/Teleport.app…"
	-@rm -rf /Applications/Teleport.app
	@echo "▶ Installing fresh bundle…"
	@cp -R ui/Teleport.app /Applications/Teleport.app
	-@xattr -cr /Applications/Teleport.app 2>/dev/null || true
	@echo "▶ Launching…"
	@open /Applications/Teleport.app
	@echo "✅ Installed and launched /Applications/Teleport.app"

clean:
	rm -rf ui/.build ui/Teleport.app ui/Resources/AppIcon.icns ui/Resources/AppIcon.png dist/
	cd daemon && cargo clean
