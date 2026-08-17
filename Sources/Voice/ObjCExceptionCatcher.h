#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const MurmurObjCExceptionErrorDomain;

/// Swift `try` does not catch `NSException`. AVAudioEngine prepare/start can
/// raise one and abort the process. Run `block` inside `@try/@catch`.
BOOL MurmurCatchObjCException(
    NS_NOESCAPE void (^block)(void),
    NSError * _Nullable __autoreleasing * _Nullable outError
);

NS_ASSUME_NONNULL_END
