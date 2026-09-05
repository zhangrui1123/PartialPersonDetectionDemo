cmake_minimum_required(VERSION 3.5.0)
project(framereceiver)

set(CMAKE_CXX_STANDARD 17)
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(framereceiver SHARED napi_init.cpp)

target_link_libraries(framereceiver PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libohimage.so
    libimage_receiver.so
    libnative_buffer.so
)
