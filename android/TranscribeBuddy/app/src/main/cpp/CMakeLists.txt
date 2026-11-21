cmake_minimum_required(VERSION 3.14)
project(transcribebuddy C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# whisper.cpp is cloned into this folder by the build workflow (see .github/workflows/build-android.yml)
set(WHISPER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp)
if (NOT EXISTS ${WHISPER_DIR}/CMakeLists.txt)
    message(FATAL_ERROR "whisper.cpp not found. Run: git clone --depth 1 --branch v1.8.2 https://github.com/ggml-org/whisper.cpp ${WHISPER_DIR}")
endif ()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)

add_subdirectory(${WHISPER_DIR} whisper_build)

add_library(whisper_jni SHARED whisper_jni.cpp)
target_include_directories(whisper_jni PRIVATE ${WHISPER_DIR}/include ${WHISPER_DIR}/ggml/include)
target_compile_options(whisper_jni PRIVATE -O3)

find_library(LOG_LIB log)
target_link_libraries(whisper_jni whisper ${LOG_LIB} android)
