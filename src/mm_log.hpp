#pragma once
//
// 极简日志：同时写 NSLog 和 App 沙盒里的文件（方便用 Filza / iMazing 取）。
//
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <functional>
#include <string>

#import <Foundation/Foundation.h>

namespace mm {

// 额外日志出口（菜单里的控制台会挂一个上来）
using LogSink = std::function<void(const std::string&)>;

inline LogSink& sink() {
    static LogSink s;
    return s;
}

inline void set_sink(LogSink s) { sink() = std::move(s); }

inline std::string& log_path() {
    static std::string path;
    if (path.empty()) {
        @autoreleasepool {
            NSArray<NSString*>* dirs =
                NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString* docs = dirs.count ? dirs[0] : NSTemporaryDirectory();
            NSString* p = [docs stringByAppendingPathComponent:@"TerrariaModMenu.log"];
            path = std::string(p.UTF8String ?: "/tmp/TerrariaModMenu.log");
        }
    }
    return path;
}

inline void logf(const char* fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    NSLog(@"[ModMenu] %s", buf);

    FILE* f = fopen(log_path().c_str(), "a");
    if (f) {
        time_t now = time(nullptr);
        char ts[32];
        strftime(ts, sizeof(ts), "%H:%M:%S", localtime(&now));
        fprintf(f, "[%s] %s\n", ts, buf);
        fclose(f);
    }

    if (sink()) {
        size_t n = strlen(buf);
        if (n && buf[n - 1] == '\n') buf[n - 1] = '\0';
        sink()(std::string(buf));
    }
}

}  // namespace mm
