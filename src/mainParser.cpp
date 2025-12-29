#include "Dashun.h"
#include "Dashun_linux.hpp"

auto parser = qing::ActParser();
int main(int argc, char** argv) {  /* argc >= 1 */
    I2C_init();
    PCA9685_init();
    parser.fromStdin();
    //parser.fromFile(argv[1]);
    parser.play();
}