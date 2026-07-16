cmake_minimum_required(VERSION 3.25)

project(vtk_flutter_native LANGUAGES C CXX)

option(
  VTK_FLUTTER_BUILD_SHARED_CORE
  "Build the monolithic VTK-backed core as a dynamic code asset"
  OFF
)

function(vtk_flutter_enable_warnings target)
  if(MSVC)
    target_compile_options(${target} PRIVATE /W4 /permissive-)
  else()
    target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic)
  endif()
endfunction()

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

if(VTK_FLUTTER_BUILD_SHARED_CORE)
  set(VTK_FLUTTER_CORE_LIBRARY_TYPE SHARED)
else()
  set(VTK_FLUTTER_CORE_LIBRARY_TYPE STATIC)
endif()

add_library(
  vtk_flutter_core
  ${VTK_FLUTTER_CORE_LIBRARY_TYPE}
    include/vtk_flutter.h
    src/callback_render_target.cxx
    src/render_target.h
    src/session.cxx
    src/session.h
    src/volume_pipeline.cxx
    src/volume_pipeline.h
    src/vtk_flutter.cxx
)
target_compile_features(vtk_flutter_core PUBLIC cxx_std_20)
target_compile_definitions(
  vtk_flutter_core
  PRIVATE VTK_FLUTTER_BUILDING_LIBRARY
)
if(NOT VTK_FLUTTER_BUILD_SHARED_CORE)
  target_compile_definitions(vtk_flutter_core PUBLIC VTK_FLUTTER_STATIC)
endif()
target_include_directories(
  vtk_flutter_core
  PUBLIC include
  PRIVATE src
)
target_link_libraries(vtk_flutter_core PUBLIC ${VTK_LIBRARIES})
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  find_library(VTK_FLUTTER_OPENGLES_FRAMEWORK OpenGLES REQUIRED)
  target_link_libraries(
    vtk_flutter_core
    PRIVATE ${VTK_FLUTTER_OPENGLES_FRAMEWORK}
  )
endif()
set_target_properties(
  vtk_flutter_core
  PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    OUTPUT_NAME vtk_flutter_core
)
if(VTK_FLUTTER_BUILD_SHARED_CORE AND NOT BUILD_TESTING)
  set_target_properties(
    vtk_flutter_core
    PROPERTIES
      CXX_VISIBILITY_PRESET hidden
      VISIBILITY_INLINES_HIDDEN ON
  )
endif()
vtk_flutter_enable_warnings(vtk_flutter_core)
vtk_module_autoinit(TARGETS vtk_flutter_core MODULES ${VTK_LIBRARIES})

include(GNUInstallDirs)
install(
  TARGETS vtk_flutter_core
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(FILES include/vtk_flutter.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

include(CTest)
if(BUILD_TESTING)
  add_library(vtk_flutter_public_header_contract OBJECT test/public_header_contract.c)
  target_compile_features(vtk_flutter_public_header_contract PRIVATE c_std_11)
  target_compile_definitions(
    vtk_flutter_public_header_contract
    PRIVATE VTK_FLUTTER_BUILDING_LIBRARY
  )
  target_include_directories(vtk_flutter_public_header_contract PRIVATE include)
  vtk_flutter_enable_warnings(vtk_flutter_public_header_contract)

  add_executable(
    vtk_flutter_core_contract_test
    test/core_contract_test.cxx
    $<TARGET_OBJECTS:vtk_flutter_public_header_contract>
  )
  target_compile_features(vtk_flutter_core_contract_test PRIVATE cxx_std_20)
  target_include_directories(vtk_flutter_core_contract_test PRIVATE include src)
  target_link_libraries(vtk_flutter_core_contract_test PRIVATE vtk_flutter_core)
  vtk_flutter_enable_warnings(vtk_flutter_core_contract_test)

  vtk_module_autoinit(
    TARGETS vtk_flutter_core_contract_test
    MODULES ${VTK_LIBRARIES}
  )

  set(
    VTK_FLUTTER_CONTRACT_CASES
    cpu_frame_copy
    public_c_and_legacy_migration
    core_table_lifecycle
    real_offscreen_render
    callback_failures
    same_session_reentry
    concurrent_renders
  )
  foreach(contract_case IN LISTS VTK_FLUTTER_CONTRACT_CASES)
    set(test_name vtk_flutter_native_core_contract_${contract_case})
    add_test(NAME ${test_name} COMMAND vtk_flutter_core_contract_test ${contract_case})
    set_tests_properties(${test_name} PROPERTIES TIMEOUT 15)
  endforeach()
endif()
