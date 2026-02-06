#include "flutter_window.h"

#include <optional>
#include <string>
#include <vector>
#include <windns.h>

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
  auto messenger = flutter_controller_->engine()->messenger();
  dns_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "wimsy/dns", &flutter::StandardMethodCodec::GetInstance());
  dns_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() != "resolveSrv") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Success(flutter::EncodableValue(flutter::EncodableList()));
          return;
        }
        auto name_it = args->find(flutter::EncodableValue("name"));
        if (name_it == args->end() || !std::holds_alternative<std::string>(name_it->second)) {
          result->Success(flutter::EncodableValue(flutter::EncodableList()));
          return;
        }
        const std::string name = std::get<std::string>(name_it->second);
        if (name.empty()) {
          result->Success(flutter::EncodableValue(flutter::EncodableList()));
          return;
        }

        std::wstring wide_name;
        wide_name.assign(name.begin(), name.end());
        DNS_RECORDW* records = nullptr;
        const DNS_STATUS status = DnsQuery_W(
            wide_name.c_str(), DNS_TYPE_SRV, DNS_QUERY_STANDARD, nullptr, &records, nullptr);
        flutter::EncodableList list;
        if (status == 0 && records != nullptr) {
          for (DNS_RECORDW* rec = records; rec != nullptr; rec = rec->pNext) {
            if (rec->wType != DNS_TYPE_SRV) {
              continue;
            }
            const auto& srv = rec->Data.SRV;
            if (srv.pNameTarget == nullptr) {
              continue;
            }
            const int len = WideCharToMultiByte(CP_UTF8, 0, srv.pNameTarget, -1, nullptr, 0, nullptr, nullptr);
            if (len <= 1) {
              continue;
            }
            std::string target;
            target.resize(len - 1);
            WideCharToMultiByte(CP_UTF8, 0, srv.pNameTarget, -1, target.data(), len, nullptr, nullptr);
            if (!target.empty() && target.back() == '.') {
              target.pop_back();
            }
            flutter::EncodableMap entry;
            entry[flutter::EncodableValue("host")] = flutter::EncodableValue(target);
            entry[flutter::EncodableValue("port")] = flutter::EncodableValue(static_cast<int>(srv.wPort));
            entry[flutter::EncodableValue("priority")] = flutter::EncodableValue(static_cast<int>(srv.wPriority));
            entry[flutter::EncodableValue("weight")] = flutter::EncodableValue(static_cast<int>(srv.wWeight));
            list.emplace_back(entry);
          }
        }
        if (records != nullptr) {
          DnsRecordListFree(records, DnsFreeRecordListDeep);
        }
        result->Success(flutter::EncodableValue(list));
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
