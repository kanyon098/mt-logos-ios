import ManagedSettings
import ManagedSettingsUI
import UIKit

/* Shield Configuration Extension (2026-11-16) — real request, with a reference
   screenshot of a competitor's own shield screen: "when an app is blocked, it
   needs a block screen like screenzen has, so just do a black screen with the
   mt. logos logo on it." Without this extension, a shielded app shows iOS's
   own generic default screen — there was never any Mt. Logos branding on it
   at all before now, regardless of anything AppBlocking.swift already did.

   This is its own small, separate binary (an app extension, same shape as
   MonitorExtension — see project.yml) that Apple's system calls to ask "what
   should the shield for this app/category/web domain look like?" It has no UI
   of its own beyond that answer; ManagedSettingsUI renders the actual screen
   from the ShieldConfiguration returned below. */
class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        mtLogosShieldConfiguration()
    }
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        mtLogosShieldConfiguration()
    }
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        mtLogosShieldConfiguration()
    }
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        mtLogosShieldConfiguration()
    }
}

/* Plain black background + the logo mark, nothing else — deliberately no title/
   subtitle text per "just a black screen with the logo." Button labels/colors
   are left unset so iOS's own default ("Close") still applies; only the
   background and icon are actually being customized here. */
private func mtLogosShieldConfiguration() -> ShieldConfiguration {
    ShieldConfiguration(
        backgroundColor: .black,
        icon: UIImage(named: "ShieldLogo")
    )
}
