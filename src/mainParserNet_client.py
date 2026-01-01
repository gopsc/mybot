import urllib.request
import argparse
import sys

def openfile(filename):
    try:
        with open(filename, "r", encoding='utf-8') as  f:
            return f.read()
        print(f"✅ 文件读取成功，内容长度: {len(post_body_str)} 字符")
    except FileNotFoundError:
        print(f"❌ 错误：指定的文件不存在 -> {args.file}")
        sys.exit(1)  # 退出程序
    except PermissionError:
        print(f"❌ 错误：没有权限读取文件 -> {args.file}")
        sys.exit(1)
    except Exception as e:
        print(f"❌ 错误：读取文件失败 -> {str(e)}")
        sys.exit(1)

def httppost(url: str, msg: str):
    try:
        # 核心转换：字符串 → 字节流（原生库必须要求）
        post_body_bytes = msg.encode("utf-8")
        # 发送POST请求，timeout=10秒防止卡死
        response = urllib.request.urlopen(url, data=post_body_bytes, timeout=2)
        
        # 解析响应结果
        if response.getcode() == 200:
            resp_content = response.read().decode("utf-8")
            print("\n🎉 请求上传成功！HTTP状态码: 200")
            print(f"🎉 服务端响应内容:\n{resp_content}")
        else:
            print(f"\n⚠️ 请求上传完成，但服务端返回异常状态码: {response.getcode()}")
            print(f"⚠️ 服务端响应内容: {response.read().decode('utf-8')}")

    except urllib.error.URLError as e:
        print(f"\n❌ 请求失败：网络错误/连接超时/端口未开放 -> {str(e)}")
    except urllib.error.HTTPError as e:
        print(f"\n❌ 请求失败：HTTP错误 -> 状态码: {e.code}, 详情: {e.read().decode('utf-8')}")
    except Exception as e:
        print(f"\n❌ 请求失败：未知错误 -> {str(e)}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="python 远程上传文本内容")
    parser.add_argument("file", type=str, help="待上传的文件")
    parser.add_argument('--port', type=int, default=9203, help="目标服务器监听端口，默认9203")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="目标服务器的IP，默认本地")
    args =parser.parse_args()
    url = f"http://{args.host}:{args.port}/bot"
    msg = openfile(args.file)
    httppost(url, msg)
