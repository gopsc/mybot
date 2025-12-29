#pragma once
#include <iostream>
#include <stdexcept>
#include "Dashun.h"
#include "Dashun_linux.hpp"
namespace qing {
class Test_nn_20251219_0 {  /* 神经网络构建与门实验 NOTE: 改造为神经网络模型类 */
public:
    void add(NeuralNetwork &layer) {
        nn.push_back(layer);
    }
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
    std::vector<std::pair<long, long>> get_shape() const {
        std::vector<std::pair<long, long>> shape;
        for (long j = 0; j < nn.size(); ++j) {
            shape.emplace_back(nn[j].get_inputno(), nn[j].get_outputno());
        }
        return shape;
    }

    void print_shape() const {
        auto shape = get_shape();
        for (const auto& p : shape) {
            std::cout << p.first << " -> " << p.second << std::endl;
        }
    }

    /*
     * 将一层非线性层分裂为两层，相当于插入一层神经元
     */
    void fork(int index, long num, float rate) {

        /* 检查参数 */
        if (index < 0 || index > nn.size() - 1) { throw std::invalid_argument("wrong index"); }

        /* 获得原来的层以及形状 */
        auto it = nn.begin() + index;
        auto oldi = (*it).get_inputno();
        auto oldo = (*it).get_outputno();

        /* 删除原来的层 */
        nn.erase(it);

        /* 创建新的层 */
        auto f0 = NeuralNetwork::ActivationFunc::Leaky_ReLU;
        auto f1 = (!index < nn.size()) ? NeuralNetwork::ActivationFunc::Leaky_ReLU : NeuralNetwork::ActivationFunc::Sigmoid;
        auto layer0 = NeuralNetwork::Create_in_Factory(oldi, num, rate, f0);
        auto layer1 = NeuralNetwork::Create_in_Factory(num, oldo, rate, f1);

        /* 插入新的层 */
        it = nn.begin() + index;
        nn.insert(it, layer1);

        it = nn.begin() + index;
        nn.insert(it, layer0);
    }

    /*
     * 神经网络生长，增加第layer层，每层增加num个神经元
     *
     * layer: 增加的层数
     * num: 增加的神经元数量
     *
     * FIXME: 神经网络生长时应当冻结其它层（除了最后一层？）（learning_rate == 0）
     */
    void grow(int layer, int num) {
        nn[layer].grow(num, true);
        if (layer >0) {
            nn[layer-1].grow(num, false);
        }
    }

    //std::string serialize() const {
    //    std::string s;
    //    for (long j=0; j<nn.size(); ++j) {
    //        s += nn[j].serialize();
    //    }
    //    return s;
    //}



private:
    std::vector<NeuralNetwork> nn;

    ////////////////////////////////////////////////////////////////////
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
    ////////////////////////////////////////////////////////////////////

    /* 前向反馈 */
    std::vector<float> forward(std::vector<float>& r) {
        auto x = r;
        for (long j=0; j< nn.size(); ++j) {
            x = nn[j].forward(x);
        }
	return x;
    }
    /* 反向传播 */
    std::vector<float> backward(std::vector<float>& errs) {
        auto e = errs;
        for (long j=nn.size()-1; j>=0;--j) {
            e = nn[j].backward(e);
            nn[j].update();
        }
	return e;
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
        if (i != 0) {
            sum += r[0];
        }

        /* 输出误差 */
        if (i % 100 == 0 && i != 0) {
            if (std::abs(sum) >= 1.0) 
                c = i;
            //std::cout << i << ":\t" << sum << std::endl;
            sum=0;
        }
    }
};
}
