#include "shader.h"

#include <glm/gtc/type_ptr.hpp>
#include <cstdio>
#include <cstdlib>

namespace {

GLuint compile(GLenum type, const char* src) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &src, nullptr);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        std::fprintf(stderr, "shader compile error: %s\n", log);
        std::exit(1);
    }
    return shader;
}

} // namespace

Shader::Shader(const char* vertexSrc, const char* fragmentSrc) {
    GLuint vs = compile(GL_VERTEX_SHADER, vertexSrc);
    GLuint fs = compile(GL_FRAGMENT_SHADER, fragmentSrc);
    id_ = glCreateProgram();
    glAttachShader(id_, vs);
    glAttachShader(id_, fs);
    glLinkProgram(id_);
    GLint ok = 0;
    glGetProgramiv(id_, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetProgramInfoLog(id_, sizeof(log), nullptr, log);
        std::fprintf(stderr, "program link error: %s\n", log);
        std::exit(1);
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
}

Shader::~Shader() {
    glDeleteProgram(id_);
}

void Shader::use() const {
    glUseProgram(id_);
}

void Shader::setMat4(const char* name, const glm::mat4& m) const {
    glUniformMatrix4fv(glGetUniformLocation(id_, name), 1, GL_FALSE, glm::value_ptr(m));
}

void Shader::setVec3(const char* name, const glm::vec3& v) const {
    glUniform3fv(glGetUniformLocation(id_, name), 1, glm::value_ptr(v));
}

void Shader::setFloat(const char* name, float v) const {
    glUniform1f(glGetUniformLocation(id_, name), v);
}
