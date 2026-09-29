import AppKit
import StationKit

// One app: Station's launch (CLI, menus, review windows) hosts Station's menu bar panel.
MainActor.assumeIsolated {
    StationHost.didLaunch = { StationMenuBar.start() }
    StationHost.openURL = { StationMenuBar.open($0) }
    StationHost.showSettings = { StationSettings.show() }
    StationHost.agentsChanged = { _, needsYou in
        if AppModel.shared.reviewAgentsNeedYou != needsYou { AppModel.shared.reviewAgentsNeedYou = needsYou }
    }
}
StationHost.main()
