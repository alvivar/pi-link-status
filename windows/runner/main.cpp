#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // One tray icon per session: a second copy of this app would add a second
  // icon polling the same hub, which is never what the user wants. The named
  // mutex is created before the engine, the window or the tray exist, so a
  // duplicate launch costs nothing and leaves no trace on screen. "Local\\"
  // scopes the name to the login session, which is the right scope for a
  // per-user tray app: another desktop session gets its own icon.
  // The handle is held for the whole active life of the engine, the window and
  // the tray icon, and closed explicitly at the end of an orderly shutdown,
  // after all of them are gone. The OS closing it is the fallback for a crash,
  // not the normal path.
  HANDLE instance_mutex =
      ::CreateMutex(nullptr, FALSE, L"Local\\pi_link_status.single_instance");
  if (instance_mutex == nullptr) {
    // A real failure to create the object, not a duplicate launch. Refusing to
    // start is safer than starting a second tray icon by accident.
    return EXIT_FAILURE;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    // Another instance already owns the tray icon. Exit quietly and without
    // touching it: no window, no engine, no activation of the running copy.
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins. Keep the result: only a successful initialization, which includes
  // S_FALSE for an already-initialized apartment, may be balanced by a call to
  // CoUninitialize.
  const HRESULT com_initialized =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  int exit_code = EXIT_SUCCESS;
  {
    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 720);
    if (window.Create(L"pi_link_status", origin, size)) {
      window.SetQuitOnClose(true);

      ::MSG msg;
      while (::GetMessage(&msg, nullptr, 0, 0)) {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      }
    } else {
      exit_code = EXIT_FAILURE;
    }
  }
  // The window is scoped so that it, the engine and the tray icon are all gone
  // before the process releases COM and the single-instance name below. Both
  // the normal exit and the failed Create() leave through here.

  if (SUCCEEDED(com_initialized)) {
    ::CoUninitialize();
  }
  ::CloseHandle(instance_mutex);
  return exit_code;
}
