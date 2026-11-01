import Foundation

nonisolated enum SaveFailure {
    static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain && error.code == 2 { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isMissing) ?? false
    }
    static func isPermission(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain && [1, 13].contains(error.code) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isPermission) ?? false
    }
}
