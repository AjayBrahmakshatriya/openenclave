# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

# TODO: Does this need CXX?

oeedl_file(../SampleAppCRT.edl enclave gen)

add_enclave(TARGET SampleAppCRT SOURCES SampleAppCRT.cpp ${gen})

target_include_directories(SampleAppCRT PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR})

target_link_libraries(SampleAppCRT oelibc)
