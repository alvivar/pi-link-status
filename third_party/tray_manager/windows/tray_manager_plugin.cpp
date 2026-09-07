#include "include/tray_manager/tray_manager_plugin.h"

// This must be included before many other Windows headers.
#include <stdio.h>
#include <windows.h>

#include <shellapi.h>
#include <strsafe.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <codecvt>
#include <functional>
#include <map>
#include <memory>
#include <sstream>
#include <string>

#include "tray_icon.h"
#include "win32_tray_shell.h"

namespace {

// Turns a failure into a method-channel error with a usable diagnostic.
std::string DescribeError(DWORD last_error) {
  std::ostringstream text;
  text << " (GetLastError=" << last_error << ")";
  return text.str();
}

const flutter::EncodableValue* ValueOrNull(const flutter::EncodableMap& map,
                                           const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return &(it->second);
}
std::unique_ptr<
    flutter::MethodChannel<flutter::EncodableValue>,
    std::default_delete<flutter::MethodChannel<flutter::EncodableValue>>>
    channel = nullptr;

class TrayManagerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  TrayManagerPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~TrayManagerPlugin();

 private:
  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> g_converter;

  flutter::PluginRegistrarWindows* registrar;
  // Declared before tray_ so it outlives it: ~TrayIcon still uses the shell.
  tray_manager::Win32TrayShell shell_{[this]() { return GetMainWindow(); }};
  tray_manager::TrayIcon tray_{&shell_};
  // do create pop-up menu only once.
  HMENU hMenu = CreatePopupMenu();
  UINT windows_taskbar_created_message_id = 0;

  // The ID of the WindowProc delegate registration.
  int window_proc_id = -1;

  void TrayManagerPlugin::_CreateMenu(HMENU menu, flutter::EncodableMap args);

  // Called for top-level WindowProc delegation.
  std::optional<LRESULT> TrayManagerPlugin::HandleWindowProc(HWND hwnd,
                                                             UINT message,
                                                             WPARAM wparam,
                                                             LPARAM lparam);
  HWND TrayManagerPlugin::GetMainWindow();
  void TrayManagerPlugin::DeactivateRecovery(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::Destroy(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetIcon(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetToolTip(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::PopUpContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::GetBounds(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

static bool plugin_already_registered = false;

// static
void TrayManagerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  if (plugin_already_registered) {
    // Skip registration in subwindow
    return;
  }
  
  plugin_already_registered = true;
  
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "tray_manager",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<TrayManagerPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

TrayManagerPlugin::TrayManagerPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar(registrar) {
  window_proc_id = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
  windows_taskbar_created_message_id = RegisterWindowMessage(L"TaskbarCreated");
}

TrayManagerPlugin::~TrayManagerPlugin() {
  registrar->UnregisterTopLevelWindowProcDelegate(window_proc_id);
}

void TrayManagerPlugin::_CreateMenu(HMENU menu, flutter::EncodableMap args) {
  flutter::EncodableList items = std::get<flutter::EncodableList>(
      args.at(flutter::EncodableValue("items")));

  int count = GetMenuItemCount(menu);
  for (int i = 0; i < count; i++) {
    // always remove at 0 because they shift every time
    RemoveMenu(menu, 0, MF_BYPOSITION);
  }

  for (flutter::EncodableValue item_value : items) {
    flutter::EncodableMap item_map =
        std::get<flutter::EncodableMap>(item_value);
    int id = std::get<int>(item_map.at(flutter::EncodableValue("id")));
    std::string type =
        std::get<std::string>(item_map.at(flutter::EncodableValue("type")));
    std::string label =
        std::get<std::string>(item_map.at(flutter::EncodableValue("label")));
    auto* checked = std::get_if<bool>(ValueOrNull(item_map, "checked"));
    bool disabled =
        std::get<bool>(item_map.at(flutter::EncodableValue("disabled")));

    UINT_PTR item_id = id;
    UINT uFlags = MF_STRING;

    if (disabled) {
      uFlags |= MF_GRAYED;
    }

    if (type.compare("separator") == 0) {
      AppendMenuW(menu, MF_SEPARATOR, item_id, NULL);
    } else {
      if (type.compare("checkbox") == 0) {
        if (checked == nullptr) {
          // skip
        } else {
          uFlags |= (*checked == true ? MF_CHECKED : MF_UNCHECKED);
        }
      } else if (type.compare("submenu") == 0) {
        uFlags |= MF_POPUP;
        HMENU sub_menu = ::CreatePopupMenu();
        _CreateMenu(sub_menu, std::get<flutter::EncodableMap>(item_map.at(
                                  flutter::EncodableValue("submenu"))));
        item_id = reinterpret_cast<UINT_PTR>(sub_menu);
      }
      AppendMenuW(menu, uFlags, item_id, g_converter.from_bytes(label).c_str());
    }
  }
}

std::optional<LRESULT> TrayManagerPlugin::HandleWindowProc(HWND hWnd,
                                                           UINT message,
                                                           WPARAM wParam,
                                                           LPARAM lParam) {
  std::optional<LRESULT> result;
  if (message == WM_DESTROY) {
    tray_.Destroy();
  } else if (message == WM_TIMER && shell_.ConsumeTimer(hWnd, wParam)) {
    // Ours, and now spent: the state machine re-arms it only if the attempt
    // fails again and the budget allows, so a permanent failure stops on its
    // own. A foreign or stale WM_TIMER falls through untouched.
    tray_.RetryNow();
  } else if (message == WM_COMMAND) {
    flutter::EncodableMap eventData = flutter::EncodableMap();
    eventData[flutter::EncodableValue("id")] =
        flutter::EncodableValue((int)wParam);

    channel->InvokeMethod("onTrayMenuItemClick",
                          std::make_unique<flutter::EncodableValue>(eventData));
  } else if (message == WM_MYMESSAGE) {
    switch (lParam) {
      case WM_LBUTTONUP:
        channel->InvokeMethod("onTrayIconMouseDown",
                              std::make_unique<flutter::EncodableValue>());
        break;
      case WM_RBUTTONUP:
        channel->InvokeMethod("onTrayIconRightMouseDown",
                              std::make_unique<flutter::EncodableValue>());
        break;
      default:
        return DefWindowProc(hWnd, message, wParam, lParam);
    };
  } else if (message == windows_taskbar_created_message_id) {
    if (windows_taskbar_created_message_id != 0) {
      // Explorer restarted and dropped every icon: register again, with a
      // fresh budget because the notification area may not accept us yet.
      tray_.Restore();
    }
  } else if (message == WM_POWERBROADCAST) {
    // Handle power management events (sleep/wake)
    switch (wParam) {
      case PBT_APMRESUMEAUTOMATIC:
      case PBT_APMRESUMESUSPEND:
        // Restore the tray icon after the system wakes up.
        tray_.Restore();
        break;
      default:
        break;
    }
  }
  return result;
}

HWND TrayManagerPlugin::GetMainWindow() {
  // Null during teardown, when the tray is still releasing what it owns.
  flutter::FlutterView* view = registrar->GetView();
  if (view == nullptr) {
    return nullptr;
  }
  return ::GetAncestor(view->GetNativeWindow(), GA_ROOT);
}

// Local addition: stops the recovery timer at once, without giving up the icon.
// The app calls this the moment it starts quitting, because its `destroy` may
// be queued behind work that takes arbitrarily long. See ../../PATCHES.md.
void TrayManagerPlugin::DeactivateRecovery(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  tray_.Deactivate();

  result->Success();
}

void TrayManagerPlugin::Destroy(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  tray_.Destroy();

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::SetIcon(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  std::string iconPath =
      std::get<std::string>(args.at(flutter::EncodableValue("iconPath")));

  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> converter;

  const tray_manager::ChannelDisposition disposition =
      tray_manager::DispositionFor(tray_.SetIcon(converter.from_bytes(iconPath)));
  if (disposition == tray_manager::ChannelDisposition::kSuccess) {
    result->Success(flutter::EncodableValue(true));
    return;
  }
  result->Error(
      tray_manager::ErrorCodeFor(disposition),
      (disposition == tray_manager::ChannelDisposition::kIconLoadFailed
           ? "LoadImage could not read " + iconPath
           : std::string("The notification area refused the icon")) +
          DescribeError(shell_.last_error()));
}

void TrayManagerPlugin::SetToolTip(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  std::string toolTip =
      std::get<std::string>(args.at(flutter::EncodableValue("toolTip")));

  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> converter;

  const tray_manager::ChannelDisposition disposition = tray_manager::
      DispositionFor(tray_.SetToolTip(converter.from_bytes(toolTip)));
  if (disposition == tray_manager::ChannelDisposition::kSuccess) {
    result->Success(flutter::EncodableValue(true));
    return;
  }
  result->Error(
      tray_manager::ErrorCodeFor(disposition),
      disposition == tray_manager::ChannelDisposition::kIconLoadFailed
          ? std::string("No tray icon is loaded, so its tooltip cannot be set")
          : "The notification area refused the tooltip" +
                DescribeError(shell_.last_error()));
}

void TrayManagerPlugin::SetContextMenu(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  _CreateMenu(hMenu, std::get<flutter::EncodableMap>(
                         args.at(flutter::EncodableValue("menu"))));

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::PopUpContextMenu(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  bool bringAppToFront =
      std::get<bool>(args.at(flutter::EncodableValue("bringAppToFront")));

  HWND hWnd = GetMainWindow();

  double x, y;

  // RECT rect;
  // Shell_NotifyIconGetRect(&niif, &rect);

  // x = rect.left + ((rect.right - rect.left) / 2);
  // y = rect.top + ((rect.bottom - rect.top) / 2);

  POINT cursorPos;
  GetCursorPos(&cursorPos);
  x = cursorPos.x;
  y = cursorPos.y;

  if (bringAppToFront) {
    SetForegroundWindow(hWnd);
  }
  TrackPopupMenu(hMenu, TPM_BOTTOMALIGN | TPM_LEFTALIGN, static_cast<int>(x),
                 static_cast<int>(y), 0, hWnd, NULL);
  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::GetBounds(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  if (!tray_.registered()) {
    result->Success();
    return;
  }

  double devicePixelRatio =
      std::get<double>(args.at(flutter::EncodableValue("devicePixelRatio")));

  RECT rect;
  Shell_NotifyIconGetRect(&shell_.identifier(), &rect);
  flutter::EncodableMap resultMap = flutter::EncodableMap();

  double x = rect.left / devicePixelRatio * 1.0f;
  double y = rect.top / devicePixelRatio * 1.0f;
  double width = (rect.right - rect.left) / devicePixelRatio * 1.0f;
  double height = (rect.bottom - rect.top) / devicePixelRatio * 1.0f;

  resultMap[flutter::EncodableValue("x")] = flutter::EncodableValue(x);
  resultMap[flutter::EncodableValue("y")] = flutter::EncodableValue(y);
  resultMap[flutter::EncodableValue("width")] = flutter::EncodableValue(width);
  resultMap[flutter::EncodableValue("height")] =
      flutter::EncodableValue(height);

  result->Success(flutter::EncodableValue(resultMap));
}

void TrayManagerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("destroy") == 0) {
    Destroy(method_call, std::move(result));
  } else if (method_call.method_name().compare("deactivateRecovery") == 0) {
    DeactivateRecovery(method_call, std::move(result));
  } else if (method_call.method_name().compare("setIcon") == 0) {
    SetIcon(method_call, std::move(result));
  } else if (method_call.method_name().compare("setToolTip") == 0) {
    SetToolTip(method_call, std::move(result));
  } else if (method_call.method_name().compare("setContextMenu") == 0) {
    SetContextMenu(method_call, std::move(result));
  } else if (method_call.method_name().compare("popUpContextMenu") == 0) {
    PopUpContextMenu(method_call, std::move(result));
  } else if (method_call.method_name().compare("getBounds") == 0) {
    GetBounds(method_call, std::move(result));
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void TrayManagerPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  TrayManagerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
