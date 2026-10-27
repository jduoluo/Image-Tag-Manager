#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  rename_channel_ = CreateSafeRenameChannel(flutter_controller_->engine()->messenger());
  information_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "image_tag_manager/app_information",
      &flutter::StandardMethodCodec::GetInstance());
  information_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "version") {
          result->Success(flutter::EncodableValue(FLUTTER_VERSION));
          return;
        }
        if (call.method_name() != "openUrl") {
          result->NotImplemented();
          return;
        }
        const auto* url = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
        const wchar_t* destination = nullptr;
        if (url && *url == "https://github.com/jduoluo/Image-Tag-Manager") {
          destination = L"https://github.com/jduoluo/Image-Tag-Manager";
        } else if (url && *url == "https://github.com/jduoluo/Image-Tag-Manager/issues") {
          destination = L"https://github.com/jduoluo/Image-Tag-Manager/issues";
        }
        if (!destination) {
          result->Error("invalid_url", "Only project URLs are supported");
          return;
        }
        const auto status = reinterpret_cast<INT_PTR>(
            ShellExecuteW(nullptr, L"open", destination, nullptr, nullptr, SW_SHOWNORMAL));
        if (status <= 32) {
          result->Error("open_failed", "Could not open browser");
        } else {
          result->Success();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  information_channel_ = nullptr;
  rename_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
