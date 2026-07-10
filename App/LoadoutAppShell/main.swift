import LoadoutKit

// Wire Sparkle before the SwiftUI app starts so the "Check for Updates…" menu
// item is present when LoadoutApp builds its command tree. See UpdaterSetup.swift.
installSparkleUpdater()

LoadoutApp.main()
