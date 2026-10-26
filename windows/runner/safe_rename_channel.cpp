#include "safe_rename_channel.h"

#include <windows.h>

#include <cstddef>
#include <cstring>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

#include <flutter/standard_method_codec.h>

namespace {
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;

std::wstring WideFromUtf8(const std::string& text) {
  if (text.empty()) return L"";
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         text.data(), static_cast<int>(text.size()),
                                         nullptr, 0);
  if (length == 0) return L"";
  std::wstring result(length, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                          static_cast<int>(text.size()), result.data(), length) == 0) {
    return L"";
  }
  return result;
}

std::string FileIdentity(HANDLE handle) {
  FILE_ID_INFO info{};
  if (!GetFileInformationByHandleEx(handle, FileIdInfo, &info, sizeof(info))) {
    return "";
  }
  std::ostringstream value;
  value << std::hex << std::setfill('0') << std::setw(16)
        << info.VolumeSerialNumber;
  for (const unsigned char byte : info.FileId.Identifier) {
    value << std::setw(2) << static_cast<unsigned>(byte);
  }
  return value.str();
}

HANDLE OpenRegularFile(const std::wstring& path, bool rename, DWORD* error) {
  const DWORD access = FILE_READ_ATTRIBUTES | (rename ? DELETE : 0);
  const DWORD sharing = FILE_SHARE_READ | FILE_SHARE_WRITE |
                        (rename ? 0 : FILE_SHARE_DELETE);
  HANDLE handle = CreateFileW(path.c_str(), access, sharing,
                              nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT,
                              nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    *error = GetLastError();
    return handle;
  }
  FILE_ATTRIBUTE_TAG_INFO attributes{};
  if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &attributes,
                                    sizeof(attributes))) {
    *error = GetLastError();
    CloseHandle(handle);
    return INVALID_HANDLE_VALUE;
  }
  if ((attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
    *error = ERROR_NOT_SUPPORTED;
    CloseHandle(handle);
    return INVALID_HANDLE_VALUE;
  }
  return handle;
}

void Fail(Result* result, DWORD code) {
  result->Error("win32", std::to_string(code));
}

const std::string* StringArgument(const flutter::EncodableMap& args,
                                  const char* name) {
  auto found = args.find(Value(name));
  if (found == args.end()) return nullptr;
  return std::get_if<std::string>(&found->second);
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<Value>> CreateSafeRenameChannel(
    flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "image_tag_manager/safe_rename",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<Value>& call,
         std::unique_ptr<Result> result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("arguments", "Expected a map");
          return;
        }
        const auto* source = StringArgument(*args, "source");
        if (source == nullptr) {
          result->Error("arguments", "Missing source");
          return;
        }
        const std::wstring from = WideFromUtf8(*source);
        if (from.empty() || !std::filesystem::path(from).is_absolute()) {
          result->Error("arguments", "Source must be an absolute UTF-8 path");
          return;
        }
        const bool rename = call.method_name() == "rename";
        const bool copy = call.method_name() == "copyNoReplace";
        if (!rename && !copy && call.method_name() != "identity") {
          result->NotImplemented();
          return;
        }
        std::wstring to;
        if (rename || copy) {
          const auto* target = StringArgument(*args, "target");
          const auto* expected = StringArgument(*args, "expectedId");
          if (target == nullptr || expected == nullptr) {
            result->Error("arguments", "Missing file operation fields");
            return;
          }
          to = WideFromUtf8(*target);
          const auto from_parent = std::filesystem::path(from).parent_path().lexically_normal().wstring();
          const auto to_parent = std::filesystem::path(to).parent_path().lexically_normal().wstring();
          if (to.empty() || !std::filesystem::path(to).is_absolute() ||
              (rename && _wcsicmp(from_parent.c_str(), to_parent.c_str()) != 0)) {
            result->Error("arguments", "Invalid target path");
            return;
          }
        }
        bool require_delete = rename;
        const auto requested_delete = args->find(Value("requireDelete"));
        if (requested_delete != args->end()) {
          const auto* value = std::get_if<bool>(&requested_delete->second);
          require_delete = require_delete || (value != nullptr && *value);
        }
        DWORD error = ERROR_SUCCESS;
        HANDLE handle = OpenRegularFile(from, require_delete, &error);
        if (handle == INVALID_HANDLE_VALUE) {
          Fail(result.get(), error);
          return;
        }
        const std::string identity = FileIdentity(handle);
        if (identity.empty()) {
          error = GetLastError();
          CloseHandle(handle);
          Fail(result.get(), error);
          return;
        }
        if (!rename && !copy) {
          CloseHandle(handle);
          result->Success(Value(identity));
          return;
        }
        const auto* expected = StringArgument(*args, "expectedId");
        if (identity != *expected) {
          CloseHandle(handle);
          result->Error("identity", "Source file identity changed");
          return;
        }
        if (copy) {
          // CopyFileW with bFailIfExists prevents replacing any existing target.
          const BOOL success = CopyFileW(from.c_str(), to.c_str(), TRUE);
          error = success ? ERROR_SUCCESS : GetLastError();
          CloseHandle(handle);
          if (!success) {
            Fail(result.get(), error);
            return;
          }
          result->Success(Value(identity));
          return;
        }
        const DWORD name_bytes = static_cast<DWORD>(to.size() * sizeof(wchar_t));
        // Windows file systems may inspect the trailing WCHARs even though
        // FileNameLength excludes them. Keep the path null-terminated in the
        // supplied buffer so no heap bytes become part of the new name.
        const size_t size = offsetof(FILE_RENAME_INFO, FileName) + name_bytes +
                            2 * sizeof(wchar_t);
        std::vector<unsigned char> storage(size, 0);
        auto* info = reinterpret_cast<FILE_RENAME_INFO*>(storage.data());
        info->ReplaceIfExists = FALSE;
        info->RootDirectory = nullptr;
        info->FileNameLength = name_bytes;
        std::memcpy(info->FileName, to.data(), name_bytes);
        const BOOL success = SetFileInformationByHandle(handle, FileRenameInfo,
                                                        info, static_cast<DWORD>(size));
        error = success ? ERROR_SUCCESS : GetLastError();
        CloseHandle(handle);
        if (!success) {
          Fail(result.get(), error);
          return;
        }
        result->Success(Value(identity));
      });
  return channel;
}
