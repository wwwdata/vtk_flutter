#import <Foundation/Foundation.h>

#include "../../../../native/include/vtk_flutter.h"

NS_ASSUME_NONNULL_BEGIN

NSDictionary<NSString*, id>* VtkFlutterCapabilitiesMap(void);
BOOL VtkFlutterDecodeViewport(id _Nullable arguments, VtkFlutterViewport* viewport,
                              NSString* _Nullable* _Nullable errorMessage);
BOOL VtkFlutterDecodeVolume(id _Nullable arguments, VtkFlutterVolume* volume,
                            NSString* _Nullable* _Nullable errorMessage);
BOOL VtkFlutterDecodeRenderRequest(id _Nullable arguments, VtkFlutterViewport viewport,
                                   VtkFlutterRenderRequest* request,
                                   NSString* _Nullable* _Nullable errorMessage);

NS_ASSUME_NONNULL_END
