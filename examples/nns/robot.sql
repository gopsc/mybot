-- Nns 原生神经网络示例：2 -> 4 -> 1，Adam，模型保存到 examples/nns/model.nn
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
VALUES ('nn', '2,4,1', 'Leaky_ReLU', 'Sigmoid',
        '0.05', 'adam', '42', 'examples/nns/model.nn', '1');
