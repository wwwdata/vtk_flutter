#import <Foundation/Foundation.h>

#include "../../../../native/include/vtk_flutter.h"

NS_ASSUME_NONNULL_BEGIN

NSDictionary<NSString*, id>* VtkFlutterCapabilitiesMap(void);
BOOL VtkFlutterDecodePresentationApi(
    id _Nullable arguments,
    const VtkFlutterPresentationApi* _Nullable* _Nonnull presentationApi,
    NSString* _Nullable* _Nullable errorMessage);
BOOL VtkFlutterDecodeNativeSession(
    id _Nullable arguments,
    VtkFlutterSession* _Nullable* _Nonnull nativeSession,
    NSString* _Nullable* _Nullable errorMessage);
BOOL VtkFlutterDecodeViewport(id _Nullable arguments, VtkFlutterViewport* viewport,
                              NSString* _Nullable* _Nullable errorMessage);

NS_ASSUME_NONNULL_END
