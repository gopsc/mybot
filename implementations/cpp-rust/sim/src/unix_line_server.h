#pragma once

#include <cstddef>
#include <string>

// 各 AF_UNIX 行文本桥（命令/拍照/测距/IMU/里程计）的公共骨架：路径校验、摘残留 inode、
// bind/listen/非阻塞、「新连接顶掉旧连接」的 accept、recv 循环 + 无换行超限断开、
// 按行切分派发、带 deadline 的整段发送。
//
// 差异点由派生类补齐：
//   handleLine   —— 一行请求的语义（改持续状态 / 置请求标志）
//   onClientGone —— 对端断开后的复位口径（命令桥回落 Stop；请求-应答桥清请求标志）
//
// EOF 语义（三桥统一）：对端关写端时**不立即断开**——先把 buffer 里已到的行全部
// 派发完，下一帧 poll() 开头再 dropClient。这正是「发完命令就断开」的 socat
// 手测模式：请求必须被处理，答复也发得出去（半关连接仍可写）。
//
// 单线程模型：无独立线程，主渲染循环每帧 poll() 一次；recv 侧非阻塞绝不卡渲染，
// 发送侧 EAGAIN 时短拍休眠等绝对 deadline，绝不无限阻塞。
class UnixLineServer {
public:
    // logTag 用于 stderr 诊断行前缀（"bridge:"/"capture:"/"sensor:"）
    UnixLineServer(const std::string& socketPath, const char* logTag,
                   std::size_t maxBufferBytes);
    virtual ~UnixLineServer();

    UnixLineServer(const UnixLineServer&) = delete;
    UnixLineServer& operator=(const UnixLineServer&) = delete;

    // 监听失败不退出：窗口照常开着，标题上标出 NOT LISTENING 让人去查路径
    bool listening() const { return listenFd_ >= 0; }
    const std::string& path() const { return path_; }

    // 每帧调一次：处理延迟断开、接受连接、收行派发
    void poll();

protected:
    // 仍有对端连接（半关写端仍算在连：答复还发得出去）
    bool hasClient() const { return clientFd_ >= 0; }
    // 整段发送；对端断开/超时/出错时已 dropClient 并返回 false
    bool sendAll(const void* data, std::size_t len);
    // 断开当前对端并回调 onClientGone 复位派生状态
    void dropClient();
    // stderr 诊断行前缀（"bridge:"/"capture:"/"sensor:"）；派生类拼告警时用
    const char* logTag() const { return logTag_; }

private:
    virtual void handleLine(const std::string& line) = 0;
    virtual void onClientGone() {}

    void acceptPending();
    void readPending();

    std::string path_;
    const char* logTag_;
    std::size_t maxBufferBytes_;
    int listenFd_ = -1;
    int clientFd_ = -1;
    std::string buffer_;
    bool clientEof_ = false;  // recv() 返回 0 时置 true，buffer 派发完下一帧再断开
};
