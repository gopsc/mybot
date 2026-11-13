-- Nns 原生神经网络示例：2 -> 8 -> 1，Tanh + Sigmoid，Adam。
-- 训练 30 轮后 XOR 的四个输出应分别接近 [0, 1, 1, 0]。
CREATE TABLE Nns (
    name String,
    layers String,
    activation String,
    output_activation String,
    learning_rate String,
    optimizer String,
    seed String,
    path String,
    autosave String
);

INSERT INTO Nns (name, layers, activation, output_activation,
                 learning_rate, optimizer, seed, path, autosave)
VALUES ('nn', '2,8,1', 'Tanh', 'Sigmoid',
        '0.1', 'adam', '42', 'examples/nns/model.nn', '1');
