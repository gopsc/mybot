#pragma once
#include <cmath>
#include "../Dashun.h"

/* FIXME: 设置为每层可调节的 */
constexpr float LEAKY_RELU_ALPHA = 0.01;
using f_t = float(*)(float);

/* 神经网络层接口 */
class ILayer {
public:

    /* 激活函数枚举类 */
    enum class ActivationFunc {
        None, ReLU, Leaky_ReLU, Sigmoid, Tanh
    };

protected:

    /* 获取函数对象 - 获取激活函数 */
    static constexpr f_t getf(ActivationFunc type) {
        switch (type) {
            case ActivationFunc::ReLU:
                return relu;
            case ActivationFunc::Leaky_ReLU:
                return leaky_relu;
            case ActivationFunc::Sigmoid:
                return sigmoid;
            case ActivationFunc::Tanh:
                return tanh;
            default:
                throw std::invalid_argument("ActivationFunc function does not support.");
        }
    }

    /* 获取函数对象 - 求激活函数导数 */
    static constexpr f_t getfdot(ActivationFunc type) {
        switch (type) {
            case ActivationFunc::ReLU:
                return relu_derivative;
            case ActivationFunc::Leaky_ReLU:
                return  leaky_relu_derivative;
            case ActivationFunc::Sigmoid:
                return sigmoid_derivative;
            case ActivationFunc::Tanh:
                return  tanh_derivative;
            default:
                throw std::invalid_argument("ActivationFunc Derivative does not support.");
        }
    }

    /* ReLU 激活函数 */
    static constexpr float relu(float x) {
        return (x > 0.0) ? x : 0.0;
    }
    /* ReLU 导数 */
    static constexpr float relu_derivative(float x) {
        return (x > 0) ? 1: 0;
    }
    /*
     * leaky ReLU 激活函数
     *
     * NOTE: alpha太小或者选择使用ReLU函数的情况下，会导致梯度消失 
     * NOTE: Leaky ReLU 不会使梯度完全消失，但也会使它变得很小
     */
    static constexpr float leaky_relu(float x) {
        return (x > 0) ? x : LEAKY_RELU_ALPHA * x;
    }
    /* leaky ReLU 导数 */
    static constexpr float leaky_relu_derivative(float x) {
        return (x > 0) ? 1.0f : LEAKY_RELU_ALPHA;
    }
    /* Sigmoid 激活函数 */
    static constexpr float sigmoid(float x) {
        return 1.0 / (1.0 + std::exp(-x));
    }
    /* Sigmoid 导数 */
    static constexpr float sigmoid_derivative(float x) {
        double s = sigmoid(x);
        return s * (1.0 - s);
    }
    /* Tanh 激活函数 */
    static constexpr float tanh(float x) {
        return std::tanh(x);
    }
    /* Tanh 导数 */
    static constexpr float tanh_derivative(float x) {
        return 1.0f - x * x;
    }
};
