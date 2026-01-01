# 什么是mybot项目

基于Linux系统的机器人项目。

# 可能的TestSuits文件夹

测试套件、工具合集

# 我是如何使用这个项目的

首先，我在家目录下创建bot文件夹，作为机器人的主目录，然后把它移动到根目录下。

我通常将该目录用于子系统的根目录，我们可以在其中创建进程模块。

```shell
cd ~
mkdir bot
sudo mv bot /
```

然后，我们可以在其中拉取一些我写好的模块，比如最核心的mybot、phs、upd、chat。

```shell
cd /bot
git clone https://github/gopsc/mybot
git clone https://github/gopsc/phs
git clone https://github/gopsc/upd
git clone https://github/gopsc/chat
```
安装这些模块的依赖，示例代码运行在Debian13
```shell
sudo apt update
sudo apt install python3 python3-pip python3-venv git cmake g++ 
```
## 还有一些库是在mybot/requirements.txt里，如果要运行也必须安装

phs是进程托管服务，类似一个子系统，我们可以进去配置它的自启动列表init.csv，以在phs服务中创建它们的进程。

其中init.csv的每一行代表一个进程的启动命令，我们可以

```text
echo 'bash ../mybot/_run.sh' > phs/init.csv
echo 'bash ../upd/_run.sh' >> phs/init.csv
echo 'bash ../chat/_run.sh' >> phs/init.csv
```
接着编辑phs/phs.service，然后将它复制到/etc/systemd/system下
```shell
vim phs/phs.service
#...
sudo cp phs/phs.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start phs
sudo systemctl status phs  # 进行检查
sudo systemctl enable phs
```

这样就能配置好这个机器人。