cmake_minimum_required(VERSION 3.25)

project(vtk_flutter_native LANGUAGES C CXX)

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

add_library(
  vtk_flutter_core
  STATIC
    include/vtk_flutter.h
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
  PUBLIC VTK_FLUTTER_STATIC
  PRIVATE VTK_FLUTTER_BUILDING_LIBRARY
)
target_include_directories(
  vtk_flutter_core
  PUBLIC include
  PRIVATE src
)
target_link_libraries(vtk_flutter_core PUBLIC ${VTK_LIBRARIES})
set_target_properties(vtk_flutter_core PROPERTIES POSITION_INDEPENDENT_CODE ON)
vtk_flutter_enable_warnings(vtk_flutter_core)
vtk_module_autoinit(TARGETS vtk_flutter_core MODULES ${VTK_LIBRARIES})

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

  add_test(NAME vtk_flutter_native_core_contract COMMAND vtk_flutter_core_contract_test)
  set_tests_properties(vtk_flutter_native_core_contract PROPERTIES TIMEOUT 15)
endif()
