#pragma once

#include <weld/build.h>

#include <string>
#include <vector>

namespace weld {
enum class CStandard {
    c99 = WELD_C_99,
    c11 = WELD_C_11,
    c17 = WELD_C_17,
    c23 = WELD_C_23,
    gnu99 = WELD_C_GNU99,
    gnu11 = WELD_C_GNU11,
    gnu17 = WELD_C_GNU17,
    gnu23 = WELD_C_GNU23,
};

enum class CppStandard {
    cpp11 = WELD_CPP_11,
    cpp14 = WELD_CPP_14,
    cpp17 = WELD_CPP_17,
    cpp20 = WELD_CPP_20,
    cpp23 = WELD_CPP_23,
};

// The fields are described at weld_executable_options in build.h. An empty name counts as left out.
struct ExecutableOptions {
    std::string name = {};
    std::vector<std::string> sources = {};
    std::vector<std::string> includes = {};
    CStandard c_standard = {};
    CppStandard cpp_standard = {};
};

// The same fields as ExecutableOptions.
struct LibraryOptions {
    std::string name = {};
    std::vector<std::string> sources = {};
    std::vector<std::string> includes = {};
    CStandard c_standard = {};
    CppStandard cpp_standard = {};
};

class Executable {
  public:
    explicit Executable(weld_executable* raw) : raw_(raw) {}
    weld_executable* raw() const {
        return raw_;
    }

  private:
    weld_executable* raw_;
};

class Library {
  public:
    explicit Library(weld_library* raw) : raw_(raw) {}
    weld_library* raw() const {
        return raw_;
    }

  private:
    weld_library* raw_;
};

namespace internal {
class CStrings {
  public:
    explicit CStrings(const std::vector<std::string>& list) {
        pointers_.reserve(list.size());
        for (const auto& s : list) {
            pointers_.push_back(s.c_str());
        }
    }
    weld_strings get() const {
        return {pointers_.data(), pointers_.size()};
    }

  private:
    std::vector<const char*> pointers_;
};

inline const char* c_name(const std::string& name) {
    return name.empty() ? nullptr : name.c_str();
}
} // namespace internal

class Build {
  public:
    explicit Build(weld_build* raw) : raw_(raw) {}
    weld_build* raw() const {
        return raw_;
    }

    Executable add_executable(const ExecutableOptions& options) {
        internal::CStrings sources(options.sources);
        internal::CStrings includes(options.includes);
        weld_executable_options c = {
            .name = internal::c_name(options.name),
            .sources = sources.get(),
            .includes = includes.get(),
            .c_standard = static_cast<weld_c_standard>(options.c_standard),
            .cpp_standard = static_cast<weld_cpp_standard>(options.cpp_standard),
        };
        return Executable(weld_add_executable(raw_, &c));
    }

    Library add_library(const LibraryOptions& options) {
        internal::CStrings sources(options.sources);
        internal::CStrings includes(options.includes);
        weld_library_options c = {
            .name = internal::c_name(options.name),
            .sources = sources.get(),
            .includes = includes.get(),
            .c_standard = static_cast<weld_c_standard>(options.c_standard),
            .cpp_standard = static_cast<weld_cpp_standard>(options.cpp_standard),
        };
        return Library(weld_add_library(raw_, &c));
    }

  private:
    weld_build* raw_;
};

} // namespace weld
