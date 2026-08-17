import Foundation

/// Swift-facing wrapper around `MurmurCatchObjCException`.
enum ObjCExceptionCatcher {
    static var errorDomain: String { MurmurObjCExceptionErrorDomain }

    static func run(_ body: @escaping () -> Void) -> Result<Void, NSError> {
        var error: NSError?
        if MurmurCatchObjCException(body, &error) {
            return .success(())
        }
        return .failure(
            error
                ?? NSError(
                    domain: errorDomain,
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "ObjC exception with no NSError"]
                )
        )
    }
}
