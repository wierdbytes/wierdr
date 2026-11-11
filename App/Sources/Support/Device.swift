import UIKit

/// What kind of device this is, for the few places that differ on iPhone
/// (terminal font and padding, wording). Layout decisions use the size
/// class too (see `WorkspaceView.usesPhoneLayout`).
@MainActor
enum Device {
    static let isPhone = UIDevice.current.userInterfaceIdiom == .phone

    /// "iPhone" / "iPad", for text such as "This iPhone's key".
    static var kind: String { isPhone ? "iPhone" : "iPad" }
}
