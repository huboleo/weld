#include <weld/build.h>

void build(weld_build* b) {
    weld_library_options options = {
        .sources = WELD_LIST("src/"),
        .includes = WELD_LIST("include/"),
    };
    weld_add_library(b, &options);
}
