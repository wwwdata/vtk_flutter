cmake_minimum_required(VERSION 3.22)

project(vtk_flutter_android LANGUAGES C)

set(VTK_FLUTTER_PACKAGE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../..")
add_library(
  vtk_flutter
  SHARED
    android_vtk_texture_adapter.c
    "${VTK_FLUTTER_PACKAGE_ROOT}/native/include/vtk_flutter.h"
)
target_compile_features(vtk_flutter PRIVATE c_std_11)
target_compile_options(vtk_flutter PRIVATE -Wall -Wextra -Wpedantic)
target_include_directories(
  vtk_flutter
  PRIVATE
    "${VTK_FLUTTER_PACKAGE_ROOT}/native/include"
)
target_link_libraries(
  vtk_flutter
  PRIVATE
    android
)
set_target_properties(
  vtk_flutter
  PROPERTIES
    C_VISIBILITY_PRESET hidden
)
