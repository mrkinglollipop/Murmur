#import "ObjCExceptionCatcher.h"

NSErrorDomain const MurmurObjCExceptionErrorDomain = @"Murmur.ObjCException";

BOOL MurmurCatchObjCException(
    NS_NOESCAPE void (^block)(void),
    NSError * _Nullable __autoreleasing * _Nullable outError
) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outError) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            if (exception.reason) {
                info[NSLocalizedDescriptionKey] = exception.reason;
            } else if (exception.name) {
                info[NSLocalizedDescriptionKey] = exception.name;
            }
            if (exception.name) {
                info[NSLocalizedFailureReasonErrorKey] = exception.name;
            }
            *outError = [NSError errorWithDomain:MurmurObjCExceptionErrorDomain
                                           code:1
                                       userInfo:info];
        }
        return NO;
    }
}
