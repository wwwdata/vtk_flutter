# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "vtk_flutter")
project(${PROJECT_NAME} LANGUAGES C CXX)
cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "vtk_flutter_plugin")
set(VTK_FLUTTER_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native")
set(VTK_FLUTTER_VTK_INSTALL
  "${CMAKE_CURRENT_SOURCE_DIR}/../.dart_tool/vtk/9.5.2/windows-x64/install"
)

if(NOT VTK_DIR)
  set(VTK_DIR
    "${VTK_FLUTTER_VTK_INSTALL}/lib/cmake/vtk-9.5"
    CACHE PATH "vtk_flutter's package-local VTK configuration"
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

set(VTK_FLUTTER_CORE_EXPORT_RENAMES
  "vtk_flutter_abi_version=vtk_flutter_core_abi_version"
  "vtk_flutter_status_clear=vtk_flutter_core_status_clear"
  "vtk_flutter_session_create=vtk_flutter_core_session_create"
  "vtk_flutter_session_destroy=vtk_flutter_core_session_destroy"
  "vtk_flutter_validate_volume=vtk_flutter_core_validate_volume"
  "vtk_flutter_session_set_volume=vtk_flutter_core_session_set_volume"
  "vtk_flutter_validate_render_request=vtk_flutter_core_validate_render_request"
  "vtk_flutter_session_render=vtk_flutter_core_session_render"
)

set(VTK_FLUTTER_NATIVE_SOURCES
  "${VTK_FLUTTER_NATIVE_DIR}/include/vtk_flutter.h"
  "${VTK_FLUTTER_NATIVE_DIR}/src/render_target.h"
  "${VTK_FLUTTER_NATIVE_DIR}/src/session.cxx"
  "${VTK_FLUTTER_NATIVE_DIR}/src/session.h"
  "${VTK_FLUTTER_NATIVE_DIR}/src/volume_pipeline.cxx"
  "${VTK_FLUTTER_NATIVE_DIR}/src/volume_pipeline.h"
  "${VTK_FLUTTER_NATIVE_DIR}/src/vtk_flutter.cxx"
)
set_source_files_properties(
  "${VTK_FLUTTER_NATIVE_DIR}/src/vtk_flutter.cxx"
  PROPERTIES COMPILE_DEFINITIONS
    "VTK_FLUTTER_STATIC;${VTK_FLUTTER_CORE_EXPORT_RENAMES}"
)

set(PLUGIN_SOURCES
  "vtk_flutter_codec.cpp"
  "vtk_flutter_codec.h"
  "vtk_flutter_native_exports.cpp"
  "vtk_flutter_native_exports.h"
  "vtk_flutter_plugin.cpp"
  "vtk_flutter_plugin.h"
  "windows_vtk_render_target.cpp"
  "windows_vtk_render_target.h"
  ${VTK_FLUTTER_NATIVE_SOURCES}
)

add_library(${PLUGIN_NAME} SHARED
  "include/vtk_flutter/vtk_flutter_plugin_c_api.h"
  "vtk_flutter_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_20)
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL
  VTK_FLUTTER_BUILDING_LIBRARY
  NOMINMAX
  WIN32_LEAN_AND_MEAN
)
target_include_directories(${PLUGIN_NAME}
  INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${VTK_FLUTTER_NATIVE_DIR}/include"
    "${VTK_FLUTTER_NATIVE_DIR}/src"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  ${VTK_LIBRARIES}
)
vtk_module_autoinit(TARGETS ${PLUGIN_NAME} MODULES ${VTK_LIBRARIES})

file(GLOB VTK_FLUTTER_RUNTIME_LIBRARIES
  "${VTK_FLUTTER_VTK_INSTALL}/bin/*.dll"
)
set(vtk_flutter_bundled_libraries
  ${VTK_FLUTTER_RUNTIME_LIBRARIES}
  PARENT_SCOPE
)

# Unit tests are built only by plugin examples that opt in.
if(include_${PROJECT_NAME}_tests)
  set(TEST_RUNNER "${PROJECT_NAME}_test")
  enable_testing()

  include(FetchContent)
  FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/archive/release-1.11.0.zip
  )
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
  FetchContent_MakeAvailable(googletest)

  add_executable(${TEST_RUNNER}
    "test/vtk_flutter_plugin_test.cpp"
    ${PLUGIN_SOURCES}
  )
  apply_standard_settings(${TEST_RUNNER})
  target_compile_features(${TEST_RUNNER} PRIVATE cxx_std_20)
  target_compile_definitions(${TEST_RUNNER} PRIVATE
    VTK_FLUTTER_STATIC
    NOMINMAX
    WIN32_LEAN_AND_MEAN
  )
  target_include_directories(${TEST_RUNNER} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${VTK_FLUTTER_NATIVE_DIR}/include"
    "${VTK_FLUTTER_NATIVE_DIR}/src"
  )
  target_link_libraries(${TEST_RUNNER} PRIVATE
    flutter_wrapper_plugin
    gtest_main
    gmock
    ${VTK_LIBRARIES}
  )
  vtk_module_autoinit(TARGETS ${TEST_RUNNER} MODULES ${VTK_LIBRARIES})

  add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${FLUTTER_LIBRARY}"
      "$<TARGET_FILE_DIR:${TEST_RUNNER}>"
  )
  foreach(VTK_RUNTIME_LIBRARY IN LISTS VTK_FLUTTER_RUNTIME_LIBRARIES)
    add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${VTK_RUNTIME_LIBRARY}"
        "$<TARGET_FILE_DIR:${TEST_RUNNER}>"
    )
  endforeach()

  include(GoogleTest)
  gtest_discover_tests(${TEST_RUNNER})
endif()
