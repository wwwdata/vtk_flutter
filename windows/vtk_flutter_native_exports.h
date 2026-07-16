#ifndef FLUTTER_PLUGIN_VTK_FLUTTER_NATIVE_EXPORTS_H_
#define FLUTTER_PLUGIN_VTK_FLUTTER_NATIVE_EXPORTS_H_

#include <mutex>

namespace vtk_flutter::windows {

// The Dart FFI transport and method-channel lifecycle can use different
// engine threads. The standalone plugin owns exactly one native session, so a
// process-local lock is sufficient to keep disposal and target replacement
// from racing exported C ABI calls.
std::mutex &NativeSessionMutex();

} // namespace vtk_flutter::windows

#endif // FLUTTER_PLUGIN_VTK_FLUTTER_NATIVE_EXPORTS_H_
