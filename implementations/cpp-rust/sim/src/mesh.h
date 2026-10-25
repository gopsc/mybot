#pragma once

#include <glad/glad.h>
#include <vector>

class Mesh {
public:
    Mesh() = default;
    Mesh(std::vector<float>&& vertices, std::vector<unsigned int>&& indices, int floatsPerVertex);
    static Mesh lines(std::vector<float>&& positions);
    ~Mesh();

    Mesh(const Mesh&) = delete;
    Mesh& operator=(const Mesh&) = delete;
    Mesh(Mesh&& other) noexcept;
    Mesh& operator=(Mesh&& other) noexcept;

    void draw() const;

private:
    GLuint vao_ = 0, vbo_ = 0, ebo_ = 0;
    GLsizei count_ = 0;
    int floatsPerVertex_ = 6;
    bool indexed_ = false;
    GLenum mode_ = GL_TRIANGLES;
};

struct SceneMeshes {
    Mesh cube;
    Mesh cylinder;
    Mesh sphere;
    Mesh grid;
};

SceneMeshes buildSceneMeshes();
