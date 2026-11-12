#include "mesh.h"

#include <cmath>
#include <utility>

namespace {

constexpr float kPi = 3.14159265358979f;

Mesh makeCube() {
    // interleaved position + normal, unit cube centered at origin
    std::vector<float> v = {
        // +X
        0.5f,-0.5f,-0.5f, 1,0,0,  0.5f, 0.5f,-0.5f, 1,0,0,  0.5f, 0.5f, 0.5f, 1,0,0,  0.5f,-0.5f, 0.5f, 1,0,0,
        // -X
        -0.5f,-0.5f, 0.5f, -1,0,0,  -0.5f, 0.5f, 0.5f, -1,0,0,  -0.5f, 0.5f,-0.5f, -1,0,0,  -0.5f,-0.5f,-0.5f, -1,0,0,
        // +Y
        -0.5f, 0.5f,-0.5f, 0,1,0,  -0.5f, 0.5f, 0.5f, 0,1,0,  0.5f, 0.5f, 0.5f, 0,1,0,  0.5f, 0.5f,-0.5f, 0,1,0,
        // -Y
        -0.5f,-0.5f, 0.5f, 0,-1,0,  -0.5f,-0.5f,-0.5f, 0,-1,0,  0.5f,-0.5f,-0.5f, 0,-1,0,  0.5f,-0.5f, 0.5f, 0,-1,0,
        // +Z
        -0.5f,-0.5f, 0.5f, 0,0,1,  0.5f,-0.5f, 0.5f, 0,0,1,  0.5f, 0.5f, 0.5f, 0,0,1,  -0.5f, 0.5f, 0.5f, 0,0,1,
        // -Z
        0.5f,-0.5f,-0.5f, 0,0,-1,  -0.5f,-0.5f,-0.5f, 0,0,-1,  -0.5f, 0.5f,-0.5f, 0,0,-1,  0.5f, 0.5f,-0.5f, 0,0,-1,
    };
    std::vector<unsigned int> idx;
    for (unsigned int f = 0; f < 6; ++f) {
        unsigned int b = f * 4;
        idx.insert(idx.end(), {b, b + 1, b + 2, b, b + 2, b + 3});
    }
    return Mesh(std::move(v), std::move(idx), 6);
}

Mesh makeCylinder(int segments) {
    std::vector<float> v;
    std::vector<unsigned int> idx;
    auto push = [&](float x, float y, float z, float nx, float ny, float nz) {
        v.insert(v.end(), {x, y, z, nx, ny, nz});
    };
    const float r = 0.5f;
    // side
    for (int i = 0; i <= segments; ++i) {
        float a = 2.0f * kPi * i / segments;
        float c = std::cos(a), s = std::sin(a);
        push(r * c, -r, r * s, c, 0, s);
        push(r * c, r, r * s, c, 0, s);
    }
    for (int i = 0; i < segments; ++i) {
        unsigned int b = i * 2;
        idx.insert(idx.end(), {b, b + 1, b + 3, b, b + 3, b + 2});
    }
    // caps
    for (int top = 1; top >= 0; --top) {
        float y = top ? r : -r;
        float ny = top ? 1.0f : -1.0f;
        unsigned int center = (unsigned int)(v.size() / 6);
        push(0, y, 0, 0, ny, 0);
        unsigned int first = center + 1;
        for (int i = 0; i <= segments; ++i) {
            float a = 2.0f * kPi * i / segments;
            push(r * std::cos(a), y, r * std::sin(a), 0, ny, 0);
        }
        for (int i = 0; i < segments; ++i) {
            if (top)
                idx.insert(idx.end(), {center, first + (unsigned)i, first + (unsigned)i + 1});
            else
                idx.insert(idx.end(), {center, first + (unsigned)i + 1, first + (unsigned)i});
        }
    }
    return Mesh(std::move(v), std::move(idx), 6);
}

Mesh makeSphere(int rings, int sectors) {
    std::vector<float> v;
    std::vector<unsigned int> idx;
    const float r = 0.5f;
    for (int i = 0; i <= rings; ++i) {
        float phi = kPi * i / rings;
        for (int j = 0; j <= sectors; ++j) {
            float theta = 2.0f * kPi * j / sectors;
            float x = std::sin(phi) * std::cos(theta);
            float y = std::cos(phi);
            float z = std::sin(phi) * std::sin(theta);
            v.insert(v.end(), {r * x, r * y, r * z, x, y, z});
        }
    }
    for (int i = 0; i < rings; ++i) {
        for (int j = 0; j < sectors; ++j) {
            unsigned int a = i * (sectors + 1) + j;
            unsigned int b = a + sectors + 1;
            idx.insert(idx.end(), {a, b, a + 1, b, b + 1, a + 1});
        }
    }
    return Mesh(std::move(v), std::move(idx), 6);
}

Mesh makeGrid(int extent, float step) {
    std::vector<float> v;
    for (float i = -extent; i <= extent + 1e-3f; i += step) {
        v.insert(v.end(), {i, 0.0f, -(float)extent, i, 0.0f, (float)extent});
        v.insert(v.end(), {-(float)extent, 0.0f, i, (float)extent, 0.0f, i});
    }
    return Mesh::lines(std::move(v));
}

} // namespace

Mesh::Mesh(std::vector<float>&& vertices, std::vector<unsigned int>&& indices, int floatsPerVertex)
    : floatsPerVertex_(floatsPerVertex), indexed_(true) {
    count_ = (GLsizei)indices.size();
    glGenVertexArrays(1, &vao_);
    glGenBuffers(1, &vbo_);
    glGenBuffers(1, &ebo_);
    glBindVertexArray(vao_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(vertices.size() * sizeof(float)), vertices.data(), GL_STATIC_DRAW);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo_);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)(indices.size() * sizeof(unsigned int)), indices.data(), GL_STATIC_DRAW);
    GLsizei stride = floatsPerVertex * sizeof(float);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, stride, (void*)0);
    if (floatsPerVertex >= 6) {
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, stride, (void*)(3 * sizeof(float)));
    }
    glBindVertexArray(0);
}

Mesh Mesh::lines(std::vector<float>&& positions) {
    Mesh m;
    m.count_ = (GLsizei)(positions.size() / 3);
    m.floatsPerVertex_ = 3;
    m.indexed_ = false;
    m.mode_ = GL_LINES;
    glGenVertexArrays(1, &m.vao_);
    glGenBuffers(1, &m.vbo_);
    glBindVertexArray(m.vao_);
    glBindBuffer(GL_ARRAY_BUFFER, m.vbo_);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(positions.size() * sizeof(float)), positions.data(), GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float), (void*)0);
    glBindVertexArray(0);
    return m;
}

Mesh::~Mesh() {
    if (vao_) glDeleteVertexArrays(1, &vao_);
    if (vbo_) glDeleteBuffers(1, &vbo_);
    if (ebo_) glDeleteBuffers(1, &ebo_);
}

Mesh::Mesh(Mesh&& other) noexcept
    : vao_(other.vao_), vbo_(other.vbo_), ebo_(other.ebo_), count_(other.count_),
      floatsPerVertex_(other.floatsPerVertex_), indexed_(other.indexed_), mode_(other.mode_) {
    other.vao_ = other.vbo_ = other.ebo_ = 0;
}

Mesh& Mesh::operator=(Mesh&& other) noexcept {
    if (this != &other) {
        if (vao_) glDeleteVertexArrays(1, &vao_);
        if (vbo_) glDeleteBuffers(1, &vbo_);
        if (ebo_) glDeleteBuffers(1, &ebo_);
        vao_ = other.vao_; vbo_ = other.vbo_; ebo_ = other.ebo_;
        count_ = other.count_; floatsPerVertex_ = other.floatsPerVertex_;
        indexed_ = other.indexed_; mode_ = other.mode_;
        other.vao_ = other.vbo_ = other.ebo_ = 0;
    }
    return *this;
}

void Mesh::draw() const {
    glBindVertexArray(vao_);
    if (indexed_)
        glDrawElements(mode_, count_, GL_UNSIGNED_INT, nullptr);
    else
        glDrawArrays(mode_, 0, count_);
    glBindVertexArray(0);
}

SceneMeshes buildSceneMeshes() {
    SceneMeshes m;
    m.cube = makeCube();
    m.cylinder = makeCylinder(36);
    m.sphere = makeSphere(12, 24);
    m.grid = makeGrid(30, 1.0f);
    return m;
}
