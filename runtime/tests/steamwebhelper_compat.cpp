#include <windows.h>
#include <shellapi.h>

#include <string>
#include <vector>

namespace {

std::wstring quote(const std::wstring &value) {
    std::wstring result = L"\"";
    unsigned backslashes = 0;
    for (wchar_t character : value) {
        if (character == L'\\') {
            ++backslashes;
        } else if (character == L'\"') {
            result.append(backslashes * 2 + 1, L'\\');
            result.push_back(L'\"');
            backslashes = 0;
        } else {
            result.append(backslashes, L'\\');
            result.push_back(character);
            backslashes = 0;
        }
    }
    result.append(backslashes * 2, L'\\');
    result.push_back(L'\"');
    return result;
}

bool hasArgument(const std::vector<std::wstring> &arguments,
                 const wchar_t *wanted) {
    for (const auto &argument : arguments) {
        if (_wcsicmp(argument.c_str(), wanted) == 0) return true;
    }
    return false;
}

// The shim holds kOriginalName as UTF-16 (see WinMain); Steam's helper never
// does. If the "original" is itself a shim (a Basalt install preserved a shim
// by mistake), launching it would make it launch itself without end: every
// Steam helper start would grow into thousands of processes.
constexpr wchar_t kOriginalName[] = L"steamwebhelper.basalt-original.exe";

bool isShim(const std::wstring &path) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    const size_t markerBytes = (sizeof(kOriginalName) - sizeof(wchar_t));
    const char *marker = reinterpret_cast<const char *>(kOriginalName);
    std::string carry;
    std::vector<char> buffer(1 << 20);
    bool found = false;
    DWORD read = 0;
    while (!found && ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                              &read, nullptr) && read > 0) {
        carry.append(buffer.data(), read);
        found = carry.find(std::string(marker, markerBytes)) != std::string::npos;
        if (carry.size() > markerBytes) carry.erase(0, carry.size() - markerBytes);
    }
    CloseHandle(file);
    return found;
}

} // namespace

int WINAPI WinMain(HINSTANCE, HINSTANCE, LPSTR, int) {
    int count = 0;
    LPWSTR *rawArguments = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!rawArguments || count < 1) return 2;
    std::vector<std::wstring> arguments;
    for (int index = 0; index < count; ++index) {
        arguments.emplace_back(rawArguments[index]);
    }
    LocalFree(rawArguments);

    wchar_t modulePath[32768];
    DWORD length = GetModuleFileNameW(nullptr, modulePath, 32768);
    if (length == 0 || length >= 32768) return 3;
    std::wstring realPath(modulePath, length);
    const auto separator = realPath.find_last_of(L"\\/");
    realPath.resize(separator == std::wstring::npos ? 0 : separator + 1);
    realPath += kOriginalName;
    if (isShim(realPath)) {
        OutputDebugStringW(L"steamwebhelper shim: the preserved original is a Basalt "
                           L"shim, not Steam's helper; refusing to launch it\n");
        return 4;
    }

    std::wstring command = quote(realPath);
    for (size_t index = 1; index < arguments.size(); ++index) {
        command.push_back(L' ');
        command += quote(arguments[index]);
    }
    for (const wchar_t *flag : {L"--no-sandbox", L"--in-process-gpu",
                                L"--disable-gpu"}) {
        if (!hasArgument(arguments, flag)) {
            command.push_back(L' ');
            command += flag;
        }
    }

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    std::vector<wchar_t> mutableCommand(command.begin(), command.end());
    mutableCommand.push_back(L'\0');
    if (!CreateProcessW(realPath.c_str(), mutableCommand.data(), nullptr, nullptr,
                        TRUE, 0, nullptr, nullptr, &startup, &process)) {
        return static_cast<int>(GetLastError());
    }
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD status = 1;
    GetExitCodeProcess(process.hProcess, &status);
    CloseHandle(process.hProcess);
    return static_cast<int>(status);
}
