#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char* const* items;
    size_t count;
} weld_strings;

#define WELD_LIST(...)                                                                             \
    ((weld_strings){(const char* const[]){__VA_ARGS__},                                            \
                    sizeof((const char* const[]){__VA_ARGS__}) / sizeof(const char*)})

typedef enum {
    WELD_C_99 = 1, // 0 is left for "not set"
    WELD_C_11,
    WELD_C_17,
    WELD_C_23,
    WELD_C_GNU99,
    WELD_C_GNU11,
    WELD_C_GNU17,
    WELD_C_GNU23,
} weld_c_standard;

typedef enum {
    WELD_CPP_11 = 1, // 0 is left for "not set"
    WELD_CPP_14,
    WELD_CPP_17,
    WELD_CPP_20,
    WELD_CPP_23,
} weld_cpp_standard;

typedef struct {
    const char* name;
    weld_strings sources;
    weld_strings includes;
} weld_executable_options;

typedef struct {
    const char* name;
    weld_strings sources;
    weld_strings includes;
} weld_library_options;

typedef struct weld_executable weld_executable;

typedef struct weld_library weld_library;

typedef struct weld_build weld_build;

weld_executable* weld_add_executable(weld_build* b, const weld_executable_options* options);

weld_library* weld_add_library(weld_build* b, const weld_library_options* options);

void build(weld_build* b);

#ifdef __cplusplus
}
#endif
