#pragma once

#include <stddef.h>

typedef struct {
    const char* const* items;
    size_t count;
} weld_strings;

#define WELD_LIST(...)                                                                             \
    ((weld_strings){(const char* const[]){__VA_ARGS__},                                            \
                    sizeof((const char* const[]){__VA_ARGS__}) / sizeof(const char*)})

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
