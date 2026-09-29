import AppKit
import onramp

// One app: Station's launch (CLI, menus, review windows) hosts Station's menu bar panel.
MainActor.assumeIsolated {
    OnrampHost.didLaunch = { StationMenuBar.start() }
    OnrampHost.openURL = { StationMenuBar.open($0) }
    OnrampHost.showSettings = { StationSettings.show() }
    OnrampHost.agentsChanged = { _, needsYou in
        if AppModel.shared.reviewAgentsNeedYou != needsYou { AppModel.shared.reviewAgentsNeedYou = needsYou }
    }
}
OnrampHost.main()
