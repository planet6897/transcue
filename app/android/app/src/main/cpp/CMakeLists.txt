# 기기 안 음성 인식: whisper.cpp (데스크톱 Homebrew와 같은 1.9.5)
cmake_minimum_required(VERSION 3.22.1)
project(transcue_whisper C CXX)

# 디버그 빌드여도 최적화 (안 하면 인식이 수십 배 느림)
set(CMAKE_C_FLAGS_DEBUG "-O3 -DNDEBUG")
set(CMAKE_CXX_FLAGS_DEBUG "-O3 -DNDEBUG")

# 64비트 ARM만 실제 인식. 다른 ABI(32비트·x86 에뮬레이터)는 빈 구현(인식 불가)으로
if(NOT ANDROID_ABI STREQUAL "arm64-v8a")
  add_library(transcue_whisper SHARED whisper_stub.cpp)
  return()
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
# 최근 ARM(갤럭시 탭 S9 등): 내적·반정밀도·8비트 행렬곱(i8mm) 명령 사용
# TODO: i8mm 없는 구형 기기용 빌드를 따로 두기 (지금은 2022년 이후 기기 대상)
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16+i8mm" CACHE STRING "" FORCE)

include(FetchContent)
FetchContent_Declare(
  whisper
  URL https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz
)
FetchContent_MakeAvailable(whisper)

add_library(transcue_whisper SHARED whisper_jni.cpp)
target_link_libraries(transcue_whisper whisper log)
