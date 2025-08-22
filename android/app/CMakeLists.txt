cmake_minimum_required(VERSION 3.22.1)

# Set your project name
project(MyAndroidApp)

# For NDK 27: define Android API level
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -D__ANDROID_API__=$ENV{ANDROID_PLATFORM_LEVEL}")

# Add your source files
add_library(
    mylibrary            # Name of your native library
    SHARED               # Shared library for Android
    src/main/cpp/native-lib.cpp   # Path to your C++ source
)

# Include Android libraries
find_library(
    log-lib
    log
)

# Link libraries
target_link_libraries(
    mylibrary
    ${log-lib}
)
