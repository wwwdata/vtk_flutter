# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "vtk_flutter")
project(${PROJECT_NAME} LANGUAGES C CXX)
cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "vtk_flutter_plugin")
set(VTK_FLUTTER_NATIVE_INCLUDE_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../native/include"
)

set(PLUGIN_SOURCES
  "vtk_flutter_codec.cpp"
  "vtk_flutter_codec.h"
  "vtk_flutter_plugin.cpp"
  "vtk_flutter_plugin.h"
  "windows_frame_target.cpp"
  "windows_frame_target.h"
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
  NOMINMAX
  WIN32_LEAN_AND_MEAN
)
target_include_directories(${PLUGIN_NAME}
  INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${VTK_FLUTTER_NATIVE_INCLUDE_DIR}"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
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
    NOMINMAX
    WIN32_LEAN_AND_MEAN
  )
  target_include_directories(${TEST_RUNNER} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${VTK_FLUTTER_NATIVE_INCLUDE_DIR}"
  )
  target_link_libraries(${TEST_RUNNER} PRIVATE
    flutter_wrapper_plugin
    gtest_main
    gmock
  )

  add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${FLUTTER_LIBRARY}"
      "$<TARGET_FILE_DIR:${TEST_RUNNER}>"
  )

  include(GoogleTest)
  gtest_discover_tests(${TEST_RUNNER})
endif()
