cmake_minimum_required(VERSION 3.22)

project(vtk_flutter_android LANGUAGES C CXX)

set(VTK_FLUTTER_PACKAGE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../..")
if(NOT DEFINED VTK_FLUTTER_NATIVE_DIR)
  set(VTK_FLUTTER_NATIVE_DIR "${VTK_FLUTTER_PACKAGE_ROOT}/native")
endif()
if(NOT DEFINED VTK_DIR)
  set(
    VTK_DIR
    "${VTK_FLUTTER_PACKAGE_ROOT}/.dart_tool/vtk/9.5.2/android-arm64/install/lib/cmake/vtk-9.5"
    CACHE PATH
    "VTK 9.5.2 Android arm64 package"
  )
endif()

find_package(
  VTK 9.5.2 EXACT CONFIG REQUIRED
  COMPONENTS
    CommonCore
    CommonDataModel
    FiltersCore
    ImagingCore
    RenderingCore
    RenderingOpenGL2
    RenderingVolumeOpenGL2
)

# The shared object is both the JNI implementation and the ffiPlugin library.
# Compiling the package core into this target keeps its public C ABI symbols in
# libvtk_flutter.so instead of allowing a static-library linker to discard them.
add_library(
  vtk_flutter
  SHARED
    android_vtk_texture_adapter.cxx
    "${VTK_FLUTTER_NATIVE_DIR}/include/vtk_flutter.h"
    "${VTK_FLUTTER_NATIVE_DIR}/src/render_target.h"
    "${VTK_FLUTTER_NATIVE_DIR}/src/session.cxx"
    "${VTK_FLUTTER_NATIVE_DIR}/src/session.h"
    "${VTK_FLUTTER_NATIVE_DIR}/src/volume_pipeline.cxx"
    "${VTK_FLUTTER_NATIVE_DIR}/src/volume_pipeline.h"
    "${VTK_FLUTTER_NATIVE_DIR}/src/vtk_flutter.cxx"
)
target_compile_features(vtk_flutter PRIVATE cxx_std_20)
target_compile_definitions(vtk_flutter PRIVATE VTK_FLUTTER_BUILDING_LIBRARY)
target_compile_options(vtk_flutter PRIVATE -Wall -Wextra -Wpedantic)
target_include_directories(
  vtk_flutter
  PRIVATE
    "${VTK_FLUTTER_NATIVE_DIR}/include"
    "${VTK_FLUTTER_NATIVE_DIR}/src"
)
target_link_libraries(
  vtk_flutter
  PRIVATE
    ${VTK_LIBRARIES}
    android
    EGL
    log
)
set_target_properties(
  vtk_flutter
  PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)

vtk_module_autoinit(TARGETS vtk_flutter MODULES ${VTK_LIBRARIES})
