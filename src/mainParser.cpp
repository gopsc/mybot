/*
 * 该文件可以解析动作脚本（.bot）并且将角度映射到动作上 。
 *
 * FIXME: 改为可以启动http服务器进行监听
 */

#include "Dashun.h"
#include "Dashun_linux.hpp"

auto parser = qing::ActParser();
int main(int argc, char** argv) {  /* argc >= 1 */
    I2C_init();
    PCA9685_init();
    parser.fromStdin();
    //parser.fromStr(argv[1]);
    parser.play();
}
