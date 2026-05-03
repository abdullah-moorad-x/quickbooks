#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kWindowTitle[] = L"QuickBill By Abdullah";
constexpr wchar_t kSingleInstanceMutex[] =
    L"Local\\QuickBillByAbdullah_SingleInstance";

struct FindWindowByTitleData {
  const wchar_t* title;
  HWND hwnd = nullptr;
};

BOOL CALLBACK FindWindowByTitle(HWND hwnd, LPARAM lparam) {
  auto* data = reinterpret_cast<FindWindowByTitleData*>(lparam);
  if (data == nullptr) {
    return FALSE;
  }

  wchar_t title[256];
  const int length = GetWindowTextW(hwnd, title, sizeof(title) / sizeof(wchar_t));
  if (length > 0 && wcscmp(title, data->title) == 0) {
    data->hwnd = hwnd;
    return FALSE;
  }
  return TRUE;
}

void ActivateExistingWindow() {
  FindWindowByTitleData data{kWindowTitle};
  EnumWindows(FindWindowByTitle, reinterpret_cast<LPARAM>(&data));
  if (data.hwnd == nullptr) {
    return;
  }

  if (IsIconic(data.hwnd)) {
    ShowWindow(data.hwnd, SW_RESTORE);
  } else {
    ShowWindow(data.hwnd, SW_SHOW);
  }
  SetForegroundWindow(data.hwnd);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  HANDLE instance_mutex = CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (instance_mutex == nullptr) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateExistingWindow();
    CloseHandle(instance_mutex);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    CloseHandle(instance_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  CloseHandle(instance_mutex);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
