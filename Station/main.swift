import AppKit
import onramp

// One app: Onramp's launch (CLI, menus, review windows) hosts Stoplight's menu bar panel.
MainActor.assumeIsolated {
    OnrampHost.didLaunch = { StationMenuBar.start() }
    OnrampHost.openURL = { StationMenuBar.open($0) }
}
OnrampHost.main()
