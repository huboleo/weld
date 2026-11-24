#pragma once

#include <weld/build.h>

#include <string>
#include <vector>

namespace weld {
struct ExecutableOptions {
    std::string name = {};
    std::vector<std::string> sources = {};
    std::vector<std::string> includes = {};
};

struct LibraryOptions {
    std::string name = {};
    std::vector<std::string> sources = {};
    std::vector<std::string> includes = {};
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
        };
        return Library(weld_add_library(raw_, &c));
    }

  private:
    weld_build* raw_;
};

} // namespace weld
