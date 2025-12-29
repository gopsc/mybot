#pragma once
#include <random>
#include "../Dashun.h"
/* 激活函数与其求导 */
using f_t = float (*) (float);

/* 人工神经网络 - 全连接层 */
class NeuralNetwork: public ILayerFullyConnectted {
public:
    /* 构造函数 使用基本参数构造 */
    NeuralNetwork(
        const long inputno, const long outputno,
        const std::vector<float> &weights,
        const std::vector<float> &bias,
        const float learning_rate,
        const ActivationFunc func_type
    ): inputno(inputno), outputno(outputno),
        weights(inputno, outputno, weights), bias( 1, outputno, bias),
        learning_rate(learning_rate),
        f_type(func_type) {
            /* 进行形状检查 */
            ;
    }


    /* 获取输入层大小 */
    long get_inputno() const {
        return this->inputno;
    }

    /* 获取输出层大小 */
    long get_outputno() const {
        return this->outputno;
    }

    
    /* 正态分布Xavier初始化 */
    static void xavierNormalInit(std::vector<float> &weights, long fan_in, long fan_out) {

        /* 高质量的随机数生成器 */
        static std::mt19937 generator(std::random_device{}());

        /* 计算标准差 */
        float sigma = std::sqrt(2.0f / (fan_in + fan_out));

        /* 创建正态分布对象，均值为0，标准差为sigma */
        std::normal_distribution<float> distribution(0.0f, sigma);

        /* 遍历权重矩阵，进行赋值 */
        long k=0;
        for (long i=0; i<fan_in; ++i) {
            for (long j=0; j<fan_out; ++j) {
                weights[k++] = distribution(generator);
            }
        }

    }
    
    // 均匀分布Xavier初始化函数
    static void xavierUniformInit(std::vector<float> &weights, int fan_in, int fan_out) {
        // 使用高质量的随机数生成器
        static std::mt19937 generator(std::random_device{}());
        
        // 计算区间范围：sqrt(2 / (fan_in + fan_out))
        float scale = std::sqrt(2.0f / (fan_in + fan_out));
        
        // 创建均匀分布对象，范围为[-scale, scale]
        std::uniform_real_distribution<float> distribution(-scale, scale);
        
        /* 遍历权重矩阵，进行赋值 */
        long k=0;
        for (long i=0; i<fan_in; ++i) {
            for (long j=0; j<fan_out; ++j) {
                weights[k++] = distribution(generator);
            }
        }
    }

    /* 工厂模式 通过形状构建全连接层 */
    static NeuralNetwork Create_in_Factory(
        const long inputno,
        const long outputno,
        float learning_rate,
        ActivationFunc func_type
    ) {
        std::vector<float> weights(inputno * outputno);
        xavierUniformInit(weights, inputno, outputno);
        std::vector<float> bias(outputno);
        NeuralNetwork layer(inputno, outputno, weights, bias, learning_rate, func_type);
        return layer; /* FIXME: 使用移动语义 */
    }

    /* 前向反馈 */
    std::vector<float> forward(const std::vector<float>& x) override {


        /*
         * 矩阵乘法（点积）
         * wi => weights inputs(column)
         * wo => weights outputs(row)
         *
         * NOTE: 通常矩阵乘法是三层循环，这里我们用两层
         */
        //std::vector<float> res(this->outputno);  /* (1, outputs) */
        //for (long i=0; i<this->outputno; ++i) {
        //    long wo = i;
        //    float sum=0.0;
        //    for (long j=0, wi=wo; j<this->inputno; ++j, wi+=this->outputno) {
        //        sum += x[j] * this->weights[wi];
        //    }
        //    res[i]= sum;
        //}
        qing::Matrx<float>mx{1, this->inputno, x};
        
        
        /*
         * 为输入进行备份
         *
         * FIXME: 使用移动语义传入参数，并且储存
         */
        this->prev_inputs = mx;  /* (1, inputs) */


        qing::Matrx<float>r = mx * this->weights;  /* (1, outputs) */

        /* 偏置操作 */
        //for (long i=0; i<this->outputno; ++i) {
        //   res[i]+=this->bias[i];
        //}
        r = r + this->bias;

        /*
         * 为原始计算结果进行备份
         */
        this->prev_raw_inputs = r;

        /*
         * 使用ReLU激活函数
         *
         * FIXME: 建立一个算法类
         */
        f_t f;
        switch (this->f_type) {
            case ActivationFunc::ReLU:
                f = relu;
                break;
            case ActivationFunc::Leaky_ReLU:
                f = leaky_relu;
                break;
            case ActivationFunc::Sigmoid:
                f=sigmoid;
                break;
            case ActivationFunc::Tanh:
                f = tanh;
                break;
            default:
                throw std::invalid_argument("ActivationFunc function does not support.");
        }

        std::vector<float> vec =r.get_data();
        for (long i=0; i<this->outputno; ++i) {
            float& v = vec[i];
            v = f(v);
        }

        r = qing::Matrx<float>(1, outputno, vec);

        /*
         * 为输出进行备份
         */
        this->prev_outputs = r;


        /* 返回前向反馈的结果。 (1, outputs) */
        return r.get_data();
    }

    /* 反向传播 */
    std::vector<float> backward(const std::vector<float>& errors) override {  /* errors => (outputs, 1) */

        /* 匹配激活导数 */
        f_t fdot;
        switch (this->f_type) {
            case ActivationFunc::ReLU:
                fdot = relu_derivative;
                break;
            case ActivationFunc::Leaky_ReLU:
                fdot = leaky_relu_derivative;
                break;
            case ActivationFunc::Sigmoid:
                fdot = sigmoid_derivative;
                break;
            case ActivationFunc::Tanh:
                fdot = tanh_derivative;
                break;
            default:
                throw std::invalid_argument("ActivationFunc Derivative does not support.");
        }

        std::vector<float> vec = this->prev_raw_inputs.get_data();
        /* 将原始输出转化为导数 */
        for (long i=0; i<this->outputno; ++i) {
            float& v = vec[i];
            v = errors[i] * fdot(v);
        }

        /* 误差乘以导数 */
        //std::vector<float> first(this->outputno);
        //for (long i=0; i<this->outputno; ++i) {
        //    first[i] = errors[i] * this->prev_raw_inputs[i];
        //}
	    qing::Matrx<float> first{1, this->outputno, vec};

        /* 更新权重梯度 => (errors * 导数) @ this->inputs => (1, outputs ) @ (inputs, 1) = (outputs, inputs) */
        //this->weights_grad = std::vector<float>(this->outputno * this->inputno);
        //long k = 0;
        //for (long i=0; i<this->inputno; ++i) {
        //    for (long j=0; j<this->outputno; ++j) {
        //        this->weights_grad[k++] = first[j] * this->prev_inputs[i];
        //    }
        //}
        qing::Matrx<float> mx {this->inputno, 1, this->prev_inputs.get_data()};  /* (inputs, 1) */
        this->weights_grad = mx * first;  /* (inputs, 1) @ (1, outputs) => (inputs, outputs) */

        /*
         * 更新偏置梯度
         *
         * NOTE: 在多批次情况下，应该沿着每一样本纵向求平均数
         */
        //this->bias_grad = std::vector<float>(this->outputno);
        //for (long i=0; i<this->outputno; ++i) {
        //    this->bias_grad[i] = first[i];
        //}
        this->bias_grad = first;


        /*
         * 计算上一层的误差责任分担，然后返回
         *
         * this->weights @ first  =>  (outputs, inputs) @ (1, outputs)  =  (inputs, 1)
         */
        //std::vector<float> uplevel_errors(this->inputno);
        //for (long i=0; i<this->inputno; ++i) {
        //    long wii = i * this->outputno;  /* 每一列的起始点 */
        //    float sum = 0.0f;
        //    for (long j=0, wi=wii; j < this->outputno; ++j, ++wi) {
        //        sum += this->weights[wi] * first[j];
        //    }
        //    uplevel_errors[i] = sum;
        //}
        qing::Matrx<float> first1{this->outputno, 1, first.get_data()};
        qing::Matrx<float> uplevel_errs = this->weights * first1;  /* (inputs, outputs) @ (outputs, 1) */
        return uplevel_errs.get_data();

        /* 使用移动语义返回上一层误差 */
        //return std::move(uplevel_errors);
    }

    /*
     * 更新权重
     *
     * 可以输入一个折扣系数
     */
    void update(float discount = 1.0) {
        this->weights = this->weights + (this->weights_grad * this->learning_rate * discount);
        this->bias    = this->bias    + (this->bias_grad    * this->learning_rate * discount);
    }
    
    /*
     * 神经网络层长大
     *
     * 重新初始化权重矩阵，使用均匀分布初始化
     *
     * num: 增加的神经元数量
     * flag: true为增加输入层，false为增加输出层
     */
    void grow(int num, bool flag) {
        this->inputno = (flag) ? this->inputno + num : this->inputno;
        this->outputno = (flag) ? this->outputno : this->outputno + num;
        auto vec = std::vector<float>(this->inputno * this->outputno);
        xavierUniformInit(vec, this->inputno, this->outputno);
        this->weights = qing::Matrx<float>(this->inputno, this->outputno, vec);
        if (!flag)
            this->bias = qing::Matrx<float>(1, this->outputno);
    }

private:

    /* 神经网络层规格 */
    long inputno, outputno;

    /* 权重与偏置矩阵 */
    qing::Matrx<float> weights; /* (outputs, inputs) */
    qing::Matrx<float> bias;    /* (1, outputs) */

    /* 学习率 */
    float learning_rate;

    /* 激活函数 */
    ActivationFunc f_type;

    /* 存储在类内部的上一次的输入，输出，和激活前输出 */
    qing::Matrx<float> prev_inputs, prev_raw_inputs, prev_outputs;
    /* 存储本次学习的权重梯度以及偏置梯度 */
    qing::Matrx<float> weights_grad, bias_grad;

};
