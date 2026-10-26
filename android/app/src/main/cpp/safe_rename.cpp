#include <jni.h>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <linux/fs.h>
#include <string>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace {
class Fd {
 public:
  explicit Fd(int value) : value_(value) {}
  ~Fd() { if (value_ >= 0) close(value_); }
  int get() const { return value_; }
 private:
  int value_;
};
void fail(JNIEnv* env, const std::string& message) {
  env->ThrowNew(env->FindClass("java/io/IOException"), message.c_str());
}
std::string bytes(JNIEnv* env, jbyteArray value) {
  if (!value) { fail(env, "Missing path"); return {}; }
  const auto count = env->GetArrayLength(value);
  std::string result(static_cast<size_t>(count), '\0');
  env->GetByteArrayRegion(value, 0, count, reinterpret_cast<jbyte*>(result.data()));
  if (result.empty() || result.find('\0') != std::string::npos || result.front() != '/') {
    fail(env, "Invalid absolute path"); return {};
  }
  return result;
}
std::string parent(const std::string& path) { return path.substr(0, path.rfind('/')); }
std::string name(const std::string& path) { return path.substr(path.rfind('/') + 1); }
std::string identity(const struct stat& file, const struct stat& dir) {
  return std::to_string(dir.st_dev) + ":" + std::to_string(dir.st_ino) + ":" +
      std::to_string(file.st_dev) + ":" + std::to_string(file.st_ino) + ":" +
      std::to_string(file.st_size) + ":" + std::to_string(file.st_mtim.tv_sec) + ":" +
      std::to_string(file.st_mtim.tv_nsec);
}
bool check(JNIEnv* env, int result, const char* operation) {
  if (result >= 0) return true;
  fail(env, std::string(operation) + ": " + strerror(errno) + " (errno " + std::to_string(errno) + ")");
  return false;
}
bool readStat(JNIEnv* env, int dir, const std::string& leaf, struct stat* value) {
  if (leaf.empty() || leaf == "." || leaf == ".." || leaf.size() > 255) {
    fail(env, "Invalid filename"); return false;
  }
  if (!check(env, fstatat(dir, leaf.c_str(), value, AT_SYMLINK_NOFOLLOW), "Read file identity")) return false;
  if (!S_ISREG(value->st_mode) || value->st_ino == 0) {
    fail(env, "Not a regular identifiable file"); return false;
  }
  return true;
}
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_image_1tag_1manager_AndroidSafeRename_nativeIdentity(JNIEnv* env, jobject, jbyteArray pathBytes) {
  const auto path = bytes(env, pathBytes);
  if (env->ExceptionCheck()) return nullptr;
  Fd dir(open(parent(path).c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
  if (!check(env, dir.get(), "Open parent directory")) return nullptr;
  struct stat directory{}, file{};
  if (!check(env, fstat(dir.get(), &directory), "Read directory identity") ||
      !readStat(env, dir.get(), name(path), &file)) return nullptr;
  return env->NewStringUTF(identity(file, directory).c_str());
}


extern "C" JNIEXPORT jstring JNICALL
Java_com_example_image_1tag_1manager_AndroidSafeRename_nativeReadableIdentity(JNIEnv* env, jobject, jbyteArray pathBytes) {
  const auto path = bytes(env, pathBytes);
  if (env->ExceptionCheck()) return nullptr;
  Fd dir(open(parent(path).c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
  if (!check(env, dir.get(), "Open parent directory")) return nullptr;
  struct stat directory{}, named{}, opened{};
  if (!check(env, fstat(dir.get(), &directory), "Read directory identity") ||
      !readStat(env, dir.get(), name(path), &named)) return nullptr;
  Fd file(openat(dir.get(), name(path).c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  if (!check(env, file.get(), "Open image for read") ||
      !check(env, fstat(file.get(), &opened), "Read opened image identity")) return nullptr;
  if (!S_ISREG(opened.st_mode) || identity(named, directory) != identity(opened, directory)) {
    fail(env, "Image identity changed while opening"); return nullptr;
  }
  return env->NewStringUTF(identity(opened, directory).c_str());
}
