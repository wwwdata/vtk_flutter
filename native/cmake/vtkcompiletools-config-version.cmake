# VTKCompileTools executables run on the build host, so their package metadata
# must not reject consumers based on the target pointer size.
set(PACKAGE_VERSION "9.6.2")

if(PACKAGE_FIND_VERSION AND PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
