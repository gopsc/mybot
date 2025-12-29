#pragma once
#include "../Dashun.h"
class ILayerFullyConnectted: public ILayer, public ILearnable {
public:
    /* 正向传播，返回神经网络输出 */
    virtual std::vector<float> forward(const std::vector<float>& inputs) = 0;
    /* 反向传播，返回上一层的误差，方便堆叠 */
    virtual std::vector<float> backward(const std::vector<float>& error) = 0;
};