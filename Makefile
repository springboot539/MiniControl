APP = build/MiniControl.app
SOURCES = Sources/main.swift Sources/WakeService.swift Sources/UCConnection.swift

.PHONY: release
release:
	mkdir -p $(APP)/Contents/MacOS
	swiftc -O -target arm64-apple-macosx13.0 $(SOURCES) -o $(APP)/Contents/MacOS/MiniControl -framework Cocoa -framework SwiftUI -framework ApplicationServices -framework Carbon -framework ServiceManagement -framework UserNotifications
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
