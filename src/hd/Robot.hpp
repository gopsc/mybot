
#include <cmath>
#include <fstream>
#include <iostream>
#include <vector>
#include <unistd.h>
#include "../Dashun_linux.hpp"

namespace qing{
class Servo{  /* 适用于180度舵机 */
public:
    Servo(int channel, float max=180, float min=0, bool rotate=false): channel(channel), max(max), min(min), rotate(rotate) {}
    void play(float target) {
        target = std::min(max, target);
        target = std::max(min, target);
        PCA9685_setAngle(channel, (rotate)?(180-target):target);
    }
    static std::vector<Servo> RobotsFactory(const std::vector<float>& limit) {
        std::vector<Servo> ss;
        for(int i=0; i<limit.size(); ++i)
            ss.push_back(Servo(i, std::abs(limit[i]), 0, (limit[i]>=0)?false:true));
        return ss;
    }
    static void RobotMove(std::vector<Servo>& ss, std::vector<float>& target) {
        if (ss.size() + 1 != target.size())
            throw std::runtime_error("Action not match this robot");
        for (int i=0; i<ss.size(); ++i) {
            ss[i].play(target[i]);
        }
	usleep(target[target.size()-1] * 1000);
    }
    static void RobotAction(std::vector<Servo>& ss, std::vector<std::vector<float>>& targets) {
        for (auto target: targets)
            RobotMove(ss, target);
    }

private:
    int channel;
    float max;
    float min;
    bool rotate;
};
}

namespace qing {
class ActParser{
public:
    void fromStdin() {
        empty_all();
        parse(std::cin);

    }
    void fromFile(const std::string& filename) {
        std::ifstream file(filename.c_str(), std::ios::in);
        if (!file.is_open())
            throw std::runtime_error("Open file failed");
        empty_all();
        parse(file);
        file.close();
    }
    void play() {
        if (bot.empty() || matrix.empty())
            throw std::runtime_error("No action or robot");
        qing::Servo::RobotAction(bot, matrix);
    }
private:
    char cs[16] = {0};
    int top = 0;
    std::vector<float> arr;
    std::vector<std::vector<float>> matrix;
    std::vector<Servo> bot;
    void parse(std::istream& in) {  /* NOTE: 修改为非静态成员函数能够减少行数 FIXME: 改为使用C++风格的文件操作 */
        empty_tmp();
        char c = 0;
        bool end_flag  = true;
        bool comment_flag  = false;
        bool obj_flag = false;
        while(end_flag) { /* 255 for arm */
            end_flag = (bool)in.get(c);
            //std::cout<<c;
            if ((!comment_flag && c >= '0' && c <= '9') || c == '+' || c == '-') {  /* 读取数字 */
                cs[top++] = c;
                std::cout<<c;
            }
            else if (!comment_flag && c == ' ') {  /* 每个角度以空格结尾 */
                cs[top] = '\0';
                submit_angle();
            }
            else if (!comment_flag && (c == '\r' || c == '\n')) {  /* 忽略回车 */
                ;
            }
            else if (!comment_flag && c == '#') {  /* 注释以#开头 */
                comment_flag = true;
            }
            else if (comment_flag && c == '\n') {  /* 注释以换行结尾 */
                comment_flag = false;
            }
            else if (comment_flag && c != '\n') {  /* 忽略注释 */
                ;
            }
            else if (!comment_flag && !obj_flag && top == 0 && c == '!') {  /* 构建模式 */
                obj_flag = true;
            }
            else if (!comment_flag && obj_flag && (c==';' || end_flag)) {  /* 构建机器人 */
                cs[top] = '\0';
                submit_angle();
                submit_robot();
                obj_flag = false;
            }   
            else if (!comment_flag && !obj_flag && (c == ';' || end_flag)) {   /* 每个动作以分号结尾 */
                cs[top] = '\0';
                submit_angle();
                submit_action();
            }
            else {
                throw std::runtime_error("Invalid action: " + std::to_string(int(c)));
            }
        }
    }

    void submit_angle() {
        if (top>0) {
            float angle = (float)atoi(cs);
            arr.push_back(angle);
            std::cout<<angle<<std::endl;
        }
        cs[0] = '\0';
        top = 0;
    }

    void submit_action() {
        if (!arr.empty()) {
            std::cout<<"recv a action: " << arr.size() << std::endl;
            matrix.push_back(arr);
            arr =  std::vector<float>{};
        }
    }

    void submit_robot() {
        if (!arr.empty()) {
            std::cout << "recv a robot: " << arr.size() << std::endl;
            bot = Servo::RobotsFactory(arr);
            arr = std::vector<float>{};
        }
    }

    void empty_tmp() {
        cs[0] = '\0';
        top = 0;
        arr = std::vector<float> {};
    }

    void empty_all() {
        cs[0] = '\0';
        top = 0;
        arr = std::vector<float> {};
        matrix = std::vector<std::vector<float>> {};
        bot = std::vector<Servo> {};
    }
};
}
