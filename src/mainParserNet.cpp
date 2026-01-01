/*
 * 该文件可以解析动作脚本（.bot）并且将角度映射到动作上 。
 */

#define HTTPLIB_COMPILE  // 无SSL需求，优先选这个；有SSL需求替换为 #define HTTPLIB_OPENSSL_SUPPORT
#include <httplib.h>
#include <string>
#include <mutex>
#include <stdexcept>
#include "Dashun.h"
#include "Dashun_linux.hpp"
constexpr int PORT = 9203;

auto svr = httplib::Server();
auto parser = qing::ActParser();
auto mtx = std::mutex();

void load() {
    svr.Post("/bot", [](const httplib::Request& req, httplib::Response& res) {
        if (!req.body.empty()) {
            try{
                mtx.lock();
                parser.fromStr(req.body);
                parser.play();
                mtx.unlock();
                res.set_content("OK", "text/plain");
            }
            catch (std::exception& exp) {
                res.set_content(exp.what(), "text/plain");
                res.status = 400;
            }
        }
        else {
            res.set_content("Empty request body", "text/plain");
            res.status = 400;
        }
    });
}

int main(int argc, char** argv) {  /* argc >= 1 */
    I2C_init();
    PCA9685_init();
    std::cout << "Bot running on http://localhost:" << PORT << std::endl;
    load();
    svr.listen("127.0.0.1", PORT);

}
