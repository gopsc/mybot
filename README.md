# pymybot

**把「结构 SQL + Python/Lua 驱动 + MT 动作」三层脚本接到真实机器人；同一套后端提供 GUI、CLI、AI Agent 和 MCP 四种入口。**

[![CI](https://github.com/gopsc/mybot/actions/workflows/ci.yml/badge.svg)](https://github.com/gopsc/mybot/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gopsc/mybot?include_prereleases&sort=semver)](https://github.com/gopsc/mybot/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Python](https://img.shields.io/badge/python-3.11%E2%80%933.14-3776AB)](pyproject.toml)

[中文使用指南](docs/Introduce.md) · [English](docs/README.en.md) · [文档索引](docs/README.md) · [路线图](docs/roadmap.md) · [安全模型](docs/security.md) · [MIT 许可证](LICENSE)

--------

### 【发起人自白】
说来我其实不喜欢用现成框架，我喜欢从零开始手搓

最开始我只是网上找了个四足蜘蛛机器人，看了下它的代码，是将每个舵机的角度和sleep的时间汇总成一个二维数组

我树莓派有文件系统，所以我就把这个数组做成了文本，就是一种矩阵的形态、

所以我表示动作的脚本是.mt

发展到现在，.mt动作脚本已经几乎成了一种编程语言。

它调用的对象由SQL声明（声明硬件），而SQL代码中能够声明的硬件类型由luajit或者python构建。

后来又在mt中加入了别名、变量、判断、循环、引入这些基本特性，以及控制器、触发器、横向合并、条件反射这些高级特性。

这么就构成了一个脚本控制系统。

