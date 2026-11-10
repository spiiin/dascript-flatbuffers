#include <fstream>
#include <iostream>
#include <iterator>
#include <vector>
#include "flatbuffers/reflection.h"
static std::vector<uint8_t> Read(const char* path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("Cannot open input file");
  return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
int main(int argc, char** argv) {
  if (argc < 3 || argc > 4) { std::cerr << "usage: fb_verify_cpp schema.bfbs buffer.bin [--size-prefixed]\n"; return 2; }
  try {
    const auto metadata = Read(argv[1]);
    flatbuffers::Verifier verifier(metadata.data(), metadata.size());
    if (!reflection::VerifySchemaBuffer(verifier)) return 2;
    const auto* schema = reflection::GetSchema(metadata.data());
    if (!schema->root_table()) return 2;
    const auto buffer = Read(argv[2]);
    bool ok = argc == 4
      ? flatbuffers::VerifySizePrefixed(*schema, *schema->root_table(), buffer.data(), buffer.size())
      : flatbuffers::Verify(*schema, *schema->root_table(), buffer.data(), buffer.size());
    std::cout << (ok ? "valid\n" : "invalid\n");
    return ok ? 0 : 1;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 2; }
}
