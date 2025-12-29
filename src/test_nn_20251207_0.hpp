#include <iostream>
#include "Dashun.h"
#include "Dashun_linux.hpp"
namespace qing {
class Test_nn_20251207_0 {
public:
    Test_nn_20251207_0() {
        init_nn();
    }
    /*
     * 神经网络构建与门实验 - 只支持单次计数，多次会累加
     */
    void run(int t) {
        float c = 0;
        for (int i=0; i<t; ++i) {
            std::vector<float> r(2);
            std::vector<float> t(1);
            prepare_data(r, t);
            forward(r);
            cal_err(r, t);
            ctrl_train(r, i, c);
            backward(r);
        }
        std::cout << "Last upper to 1%: " << c << std::endl;
    }

private:
    std::vector<NeuralNetwork> nn;
    /* 初始化神经网络模型 */
    void init_nn() {
        nn.push_back(NeuralNetwork::Create_in_Factory(2, 2, 0.1, NeuralNetwork::ActivationFunc::Leaky_ReLU));
        nn.push_back(NeuralNetwork::Create_in_Factory(2, 2, 0.1, NeuralNetwork::ActivationFunc::Leaky_ReLU));
        nn.push_back(NeuralNetwork::Create_in_Factory(2, 1, 0.1, NeuralNetwork::ActivationFunc::Leaky_ReLU));
    }
    /* 随机生成0或1 */
    static float gen_0_or_1() {
        static std::random_device rd;
        static std::mt19937_64 engine(rd());
        static std::uniform_real_distribution<> dist(0.0, 1.0);
        return (dist(engine) > 0.5 ) ? 0.99 : 0;
    }
    /* 传统与门 */
    static float and_door(float a, float b) {
        return a && b;
    }
    /*  */
    static void prepare_data(std::vector<float>& r, std::vector<float>& t) {
        r[0] = gen_0_or_1();
        r[1] = gen_0_or_1();
        t[0]  = and_door(r[0], r[1]);
    }
    /* 前向反馈 */
    void forward(std::vector<float>& r) {
        for (long j=0; j< nn.size(); ++j) {
            r = nn[j].forward(r);
        }
    }
    /* 计算误差 */
    void cal_err(std::vector<float>& r, std::vector<float>& t) {
        for (long j=0; j<r.size(); ++j) {
            r[j] = t[j] - r[j];
        }
    }
    /* 训练控制 */
    void ctrl_train(std::vector<float>& r, int i, float& c) {
        /* 统计误差 */
        static float sum;
        static int k = 0;
        if (i != 0) {
            sum += r[0];
        }

        /* 输出误差 */
        if (i % 100 == 0 && i != 0) {
            if (std::abs(sum) >= 1.0) 
                c = k;
            std::cout << k++ << ":\t" << sum << std::endl;
            sum=0;
        }
    }
    /* 反向传播 */
    void backward(std::vector<float> errs) {
        for (long j=nn.size()-1; j>=0;--j) {
            errs = nn[j].backward(errs);
            nn[j].update();
        }
    }
};
}