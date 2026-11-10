#include <cstdlib>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>
#include "flatbuffers/code_generator.h"
#include "flatbuffers/util.h"
#ifdef _WIN32
#include <process.h>
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace flatbuffers {
namespace {
std::string Config(const char* key, const char* fallback) {
  const char* value = std::getenv(key);
  return value && *value ? value : fallback;
}
int Run(const std::vector<std::string>& args) {
  std::vector<const char*> argv;
  for (const auto& arg : args) argv.push_back(arg.c_str());
  argv.push_back(nullptr);
#ifdef _WIN32
  return static_cast<int>(_spawnvp(_P_WAIT, argv[0], argv.data()));
#else
  const auto pid = fork();
  if (pid < 0) return -1;
  if (pid == 0) { execvp(argv[0], const_cast<char* const*>(argv.data())); _exit(127); }
  int status = 0;
  if (waitpid(pid, &status, 0) < 0) return -1;
  return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
#endif
}
class DascriptGenerator final : public CodeGenerator {
 public:
  Status GenerateCode(const Parser& input, const std::string& path,
                      const std::string& filename) override {
    // FlatCompiler owns a mutable Parser. Serialize is the public BFBS API;
    // this adapter only runs for schema inputs, never for JSON data files.
    auto& parser = const_cast<Parser&>(input);
    parser.opts.binary_schema_comments = true;
    parser.opts.binary_schema_builtins = true;
    parser.Serialize();
    std::filesystem::path directory(path.empty() ? "." : path);
    std::filesystem::create_directories(directory);
    const auto stem = directory / (filename + "_generated");
    const auto bfbs = stem.string() + ".bfbs";
    if (!SaveFile(bfbs.c_str(), reinterpret_cast<const char*>(parser.builder_.GetBufferPointer()), parser.builder_.GetSize(), true)) {
      status_detail = "Cannot write intermediate BFBS";
      return ERROR;
    }
    const auto code = stem.string() + ".das";
    const auto schema = stem.string() + ".fbs";
    const auto annotations = std::filesystem::relative(
      Config("DAS_FLATBUFFERS_ANNOTATIONS", DAS_ANNOTATIONS_DEFAULT),
      std::filesystem::absolute(directory)).generic_string();
    const int result = Run({Config("DASLANG", DASLANG_DEFAULT), "-no-module-cache", "-no-dynamic-modules",
      Config("DAS_FLATBUFFERS_GENERATOR", DAS_GENERATOR_DEFAULT), "--", bfbs, code, schema,
      annotations});
    if (result != 0) { status_detail = "daScript generator failed; inspect its diagnostics"; return ERROR; }
    return OK;
  }
  Status GenerateCode(const uint8_t*, int64_t, const CodeGenOptions&) override { return NOT_IMPLEMENTED; }
  Status GenerateMakeRule(const Parser&, const std::string&, const std::string&, std::string&) override { return NOT_IMPLEMENTED; }
  Status GenerateGrpcCode(const Parser&, const std::string&, const std::string&) override { return NOT_IMPLEMENTED; }
  Status GenerateRootFile(const Parser&, const std::string&) override { return NOT_IMPLEMENTED; }
  bool IsSchemaOnly() const override { return true; }
  bool SupportsBfbsGeneration() const override { return false; }
  bool SupportsRootFileGeneration() const override { return false; }
  // Use C++'s parser capability mask for advanced unions/arrays/offset64.
  // This is a standalone adapter, not a new upstream Language enum value.
  IDLOptions::Language Language() const override { return IDLOptions::kCpp; }
  std::string LanguageName() const override { return "daScript"; }
};
}
std::unique_ptr<CodeGenerator> NewDascriptCodeGenerator() { return std::unique_ptr<CodeGenerator>(new DascriptGenerator()); }
}
