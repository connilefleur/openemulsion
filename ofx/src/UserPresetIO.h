// SPDX-License-Identifier: MPL-2.0

#pragma once

#ifdef _WIN32
#include <Windows.h>
#include <commdlg.h>
#else
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif
#include <array>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>
#include "UserPresetConfig.h"

namespace userpreset {

#ifdef _WIN32
inline std::optional<std::filesystem::path> chooseFile(bool save)
{
    std::array<wchar_t, 32768> filename {};
    OPENFILENAMEW dialog {};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = GetActiveWindow();
    dialog.lpstrFilter = L"OpenEmulsion Presets (*.oepreset)\0*.oepreset\0JSON Files (*.json)\0*.json\0\0";
    dialog.nFilterIndex = 1;
    dialog.lpstrFile = filename.data();
    dialog.nMaxFile = static_cast<DWORD>(filename.size());
    dialog.lpstrDefExt = L"oepreset";
    dialog.lpstrTitle = save ? L"Save OpenEmulsion Preset" : L"Load OpenEmulsion Preset";
    dialog.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST | OFN_DONTADDTORECENT |
        (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    if (save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog))
        return std::filesystem::path(filename.data());
    if (CommDlgExtendedError() != 0) throw std::runtime_error("Could not open the preset file dialog.");
    return std::nullopt;
}
#else
namespace detail {

inline std::string findExecutable(const char* name)
{
    const char* path = std::getenv("PATH");
    std::string list = path ? path : "/usr/local/bin:/usr/bin:/bin";
    size_t start = 0;
    while (start <= list.size()) {
        size_t end = list.find(':',start);
        if (end == std::string::npos) end = list.size();
        std::string dir = list.substr(start,end - start);
        if (dir.empty()) dir = ".";
        const std::string candidate = dir + "/" + name;
        if (access(candidate.c_str(),X_OK) == 0 && !std::filesystem::is_directory(candidate)) return candidate;
        start = end + 1;
    }
    return {};
}

// Runs argv without a shell (no injection from paths). Returns exit status, -1 on failure; stdout in output.
inline int runCapture(const std::vector<std::string>& args, std::string& output)
{
    int fds[2];
    if (pipe(fds) != 0) return -1;
    std::vector<char*> argv;
    for (const auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
    argv.push_back(nullptr);
    const pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); return -1; }
    if (pid == 0) {
        dup2(fds[1],STDOUT_FILENO);
        close(fds[0]); close(fds[1]);
        execv(argv[0],argv.data());
        _exit(127);
    }
    close(fds[1]);
    char buffer[4096];
    ssize_t n;
    while ((n = read(fds[0],buffer,sizeof(buffer))) != 0) {
        if (n < 0) { if (errno == EINTR) continue; break; }
        output.append(buffer,static_cast<size_t>(n));
    }
    close(fds[0]);
    int status = 0;
    while (waitpid(pid,&status,0) < 0) if (errno != EINTR) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

} // namespace detail

inline std::optional<std::filesystem::path> chooseFile(bool save)
{
    const char* home = std::getenv("HOME");
    const std::string directory = (home && *home) ? std::string(home) + "/" : std::string("./");
    const std::string title = save ? "Save OpenEmulsion Preset" : "Load OpenEmulsion Preset";
    std::vector<std::string> args;
    if (const std::string kdialog = detail::findExecutable("kdialog"); !kdialog.empty()) {
        args = {kdialog,"--title",title,save ? "--getsavefilename" : "--getopenfilename",directory,
            "*.oepreset *.json|OpenEmulsion Presets (*.oepreset *.json)"};
    } else if (const std::string zenity = detail::findExecutable("zenity"); !zenity.empty()) {
        args = {zenity,"--file-selection","--title=" + title,"--filename=" + directory,
            "--file-filter=OpenEmulsion Presets (*.oepreset *.json) | *.oepreset *.json"};
        if (save) { args.push_back("--save"); args.push_back("--confirm-overwrite"); }
    } else {
        throw std::runtime_error("Could not open the preset file dialog: neither kdialog nor zenity is installed.");
    }
    std::string output;
    const int status = detail::runCapture(args,output);
    if (status == 1) return std::nullopt; // cancelled
    if (status != 0) throw std::runtime_error("Could not open the preset file dialog.");
    while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) output.pop_back();
    if (output.empty()) return std::nullopt;
    std::filesystem::path chosen(output);
    if (save && !chosen.has_extension()) chosen += ".oepreset";
    return chosen;
}
#endif

inline Snapshot loadFile(const std::filesystem::path& path)
{
    std::ifstream file(path,std::ios::binary);
    if (!file) throw std::runtime_error("Could not open the preset file.");
    std::string contents(MaximumBytes + 1,'\0');
    file.read(contents.data(),static_cast<std::streamsize>(contents.size()));
    if (file.bad()) throw std::runtime_error("Could not read the preset file.");
    contents.resize(static_cast<size_t>(file.gcount()));
    return parse(contents);
}

#ifdef _WIN32
inline void saveFile(const std::filesystem::path& path, const Snapshot& preset)
{
    const auto contents = serialize(preset);
    static std::atomic<unsigned long long> sequence {0};
    std::filesystem::path temporary;
    HANDLE file = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 32; ++attempt) {
        temporary = path;
        temporary += L".tmp." + std::to_wstring(GetCurrentProcessId()) + L"." +
            std::to_wstring(GetTickCount64()) + L"." + std::to_wstring(sequence.fetch_add(1));
        file = CreateFileW(temporary.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        if (file != INVALID_HANDLE_VALUE || GetLastError() != ERROR_FILE_EXISTS) break;
    }
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("Could not create the preset file in this folder.");
    DWORD written = 0;
    const bool saved = WriteFile(file,contents.data(),static_cast<DWORD>(contents.size()),&written,nullptr) &&
        written == contents.size() && FlushFileBuffers(file);
    const bool closed = CloseHandle(file) != 0;
    // Write beside the target, then replace it only after the complete file is flushed.
    if (!saved || !closed || !MoveFileExW(temporary.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(temporary.c_str());
        throw std::runtime_error("Could not save the complete preset; the previous file was not replaced.");
    }
}
#else
inline void saveFile(const std::filesystem::path& path, const Snapshot& preset)
{
    const auto contents = serialize(preset);
    static std::atomic<unsigned long long> sequence {0};
    std::filesystem::path temporary;
    int fd = -1;
    for (int attempt = 0; attempt < 32; ++attempt) {
        temporary = path;
        temporary += ".tmp." + std::to_string(getpid()) + "." + std::to_string(sequence.fetch_add(1));
        fd = open(temporary.c_str(),O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,0644);
        if (fd >= 0 || errno != EEXIST) break;
    }
    if (fd < 0) throw std::runtime_error("Could not create the preset file in this folder.");
    bool saved = true;
    size_t offset = 0;
    while (saved && offset < contents.size()) {
        const ssize_t n = write(fd,contents.data() + offset,contents.size() - offset);
        if (n < 0) { if (errno != EINTR) saved = false; }
        else offset += static_cast<size_t>(n);
    }
    saved = saved && fsync(fd) == 0;
    const bool closed = close(fd) == 0;
    // Write beside the target, then replace it only after the complete file is flushed.
    if (!saved || !closed || rename(temporary.c_str(),path.c_str()) != 0) {
        unlink(temporary.c_str());
        throw std::runtime_error("Could not save the complete preset; the previous file was not replaced.");
    }
}
#endif

} // namespace userpreset
