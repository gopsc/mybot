/*
 *  ActionSource：可替换的动作输入源工厂
 *
 *  设计动机：bot4cj 原有入口仅支持 stdin 管道读 .mt。
 *  本模块将"动作输入"抽象为 InputStream，支持三种源：
 *    - stdin（缺省，向后兼容）
 *    - TCP socket（--tcp <port>，长驻模式，客户端可下发 .mt）
 *    - 文件（--input <path>，单次执行后退出）
 *
 *  与 RobotStruct.cj 的集成：RobotStruct.run(input: InputStream) 已接受 InputStream，
 *  本工厂返回的 InputStream 直接传入即可，核心侧零改动。
 *
 *  注意（Cangjie std.io 事实，1.0.x/1.1.x 一致）：InputStream 是【字节流】
 *  接口，唯一抽象成员为 read(buffer: Array<Byte>): Int64（读到 EOF 返回 0），
 *  并没有 read(): ?Rune 字符方法；字符读取由 StringReader/ConsoleReader 等
 *  包装提供。File 与 TcpSocket 本身即 InputStream，无需 getReader() 转换。
 */

package bot4cj

import std.io.*
import std.net.*
import std.env.*
import std.fs.*
import std.collection.*
import std.convert.*

/* ---- ActionSource 工厂：tcp > input > stdin ---- */
/* 参数取 ReadOnlyMap：std.argopt 解析出的 options 即该类型（只需读操作） */
public func openActionSource(options: ReadOnlyMap<String, String>): Option<InputStream> {
	/* ---- TCP 模式（最高优先级）---- */
	if (options.contains("tcp")) {
		let portStr = options["tcp"]
		/* 解析失败按 -1 处理，与越界值共用同一校验/报错路径 */
		let port = try { Int64.parse(portStr) } catch (e: Exception) { -1 }
		if (port < 1 || port > 65535) {
			println("--tcp 端口号无效：${portStr}（合法范围 1-65535）")
			return None
		}
		return Some(openTcpActionSource(port))
	}

	/* ---- 文件模式（File 本身即字节 InputStream）---- */
	if (options.contains("input")) {
		let path = options["input"]
		try {
			let f = File(path, OpenMode.Read)
			println("从文件读取动作脚本：${path}")
			return Some(f)
		} catch (e: Exception) {
			println("无法打开动作脚本文件 '${path}': ${e.message}")
			return None
		}
	}

	/* ---- 缺省：stdin ---- */
	return Some(getStdIn())
}

/*
 * 打开 TCP 动作源：监听 0.0.0.0:<port>，接受第一个客户端连接，
 * 返回适配为 InputStream 的包装（断连时读为 EOF 而非抛异常）。
 *
 * 仓颉 stdlib API：
 *   TcpServerSocket(bindAt: UInt16) → .bind() → .accept() → TcpSocket
 *   TcpSocket 本身即为 InputStream（read(Array<Byte>) 字节流）。
 */
public func openTcpActionSource(port: Int64): InputStream {
	let port16 = UInt16(port)
	println("TCP 动作源：监听 0.0.0.0:${port16}，等待客户端连接...")
	let server = TcpServerSocket(bindAt: port16)
	server.bind()
	let sock = server.accept()
	let peer = sock.remoteAddress
	println("TCP 客户端已连接：${peer}")
	return TcpStreamReader(sock)
}

/*
 * TcpStreamReader：TcpSocket 字节流的断连安全包装。
 *
 * InputStream 是字节流接口（read(buffer): Int64，EOF 返 0）；.mt 脚本为
 * 纯 ASCII，字节即字符，消费端 StringReader 按字节做 UTF-8 解码即可。
 * 对端关闭连接时 socket 可能抛 SocketException，此处吞掉并返回 0（EOF），
 * 让上层 run() 像读到管道 EOF 一样正常收尾，而不是 abort 退出。
 */
public class TcpStreamReader <: InputStream {

	private let sock: TcpSocket

	public init(sock: TcpSocket) {
		this.sock = sock
	}

	public func read(buffer: Array<Byte>): Int64 {
		try {
			return sock.read(buffer)
		} catch (e: SocketException) {
			if (!sock.isClosed()) {
				sock.close()
			}
			return 0
		}
	}
}
