/*
 * ---------------- 守护线程硬件变量（@Daemon，自 RobotStruct.cj 迁出） ----------------
 *  用 Cangjie spawn 原语起守护线程（运行时已附着，区别于 pthread4cj 裸线程——
 *  后者在 foreign 线程上跑 Cangjie @C 代码必崩，已 PoC 证伪）。线程上创建
 *  【独立 lua_State】，loadfilex 采样 chunk 一次 + pcall 一次（chunk 内 while 循环
 *  轮询停止标志）。线程与其 lua_State 1:1 独占，主线程绝不触碰该状态机。
 *
 *  IPC：共享内存槽 daemon_slot_t（布局见 modules/lib/pthread.lua，两侧严格一致），
 *  守护侧 Lua 经 pthread.lua 的 publish 写值（mutex 保护），主线程侧 play 经
 *  foreign pthread_mutex 加锁读取，防撕裂。
 */

package bot4cj.HV
import std.convert.*
import std.collection.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*
import ctype4cj.*
import luajit4cj.*
import pthread4cj.*
import mt2.*

/* ---- 共享槽 daemon_slot_t 布局偏移（必须与 modules/lib/pthread.lua 一致）----
 * P：values 扩容到 32 通道（原 16），支撑单守护聚合多路传感器（多 IMU/气感/里程计）；
 * 前缀偏移 count(64)/nvals(68)/values(72) 不变；values[32] 占 256B 后 stop 紧跟其后，
 * 经 C 编译器 8 字节对齐落 328，槽总大小 336（gcc __builtin_offsetof 实测）。 */
public let SLOT_COUNT_OFF: Int64 = 64		/* int32：publish 次数 */
public let SLOT_NVALS_OFF: Int64 = 68		/* int32：本次值个数 */
public let SLOT_VALUES_OFF: Int64 = 72		/* double[32]：采样值 */
public let SLOT_STOP_OFF: Int64 = 328		/* uint8：停止标志 */
public let SLOT_SIZE: Int64 = 336
public let SLOT_MAXVALS: Int64 = 32

/* ---- pthread CFunc（_mutex_init/destroy/lock/unlock）由 pthread4cj 提供 ---- */

/* ---- stop 标志读写：统一经槽内 mutex 临界区 ----
 * mutex 的 lock/unlock 提供 acquire/release 内存语义，清除守护线程与主线程
 * 裸读写 stop 的数据竞争（P2：原 (slot+SLOT_STOP_OFF).read()/write(1u8) 为无序访问，
 * arm64 弱内存序下理论可见性延迟）。锁临界区极短、无嵌套，无死锁风险。 */
public func daemon_request_stop(slot: CPointer<UInt8>): Unit {
	unsafe {
		_mutex_lock(slot)
		(slot + SLOT_STOP_OFF).write(1u8)
		_mutex_unlock(slot)
	}
}

public func daemon_stop_requested(slot: CPointer<UInt8>): Bool {
	unsafe {
		_mutex_lock(slot)
		let s = (slot + SLOT_STOP_OFF).read()
		_mutex_unlock(slot)
		return s != 0u8
	}
}

/* ---- 可变状态持有者：rise/free 闭包捕获此 let 引用并改其字段，
 *      规避 Cangjie「lambda 捕获可变变量」限制 ---- */
public class DaemonHolder {
	public let slot: CPointer<UInt8>
	public let joinTimeoutMs: Int64
	public var future: Option<Future<Int64>>
	public init(slot!: CPointer<UInt8>, joinTimeoutMs!: Int64) {
		this.slot = slot
		this.joinTimeoutMs = joinTimeoutMs
		this.future = None
	}
}

/* ---- 守护线程体（spawn 绿色线程上运行）：建私有 lua_State，注入槽地址+配置，
 *      先跑 chunk 一次完成 setup 并定义全局 daemon_tick，随后逐拍驱动 ---- */
public func daemon_body(slot: CPointer<UInt8>, chunk: CString, config: CString, interval_ms: Int64): Int64 {
	unsafe {
		let L = Lua_init()
		if (Lua_check(L) == LUA_ERR) { Lua_free(L); return -1i64 }
		Lua_loadlib(L)
		sandbox_lua(L)	/* 中和 os.execute/io.popen 等宿主入口（issue #9 M1） */

		/* 注入共享槽地址（整数）与配置串（"k=v;k=v"）为 Lua 全局；
		 * Lua_setfield 会立即复制 key，调用返回后 malloc 的 key 串即可释放（P6/M4）。
		 * 地址经 lua_pushinteger 以 64 位整数 tag 注入，任意值（含 ≥2^53）逐位保真；
		 * Lua 侧只许原样 ffi.cast 直传句柄，禁止对地址做算术/tonumber（≥2^53 丢位）——
		 * 对应契约在 modules/lib/pthread.lua 顶层注释。 */
		Lua_pushinteger(L, Int64(slot.toUIntNative()))
		withCString("DAEMON_SLOT_ADDR") { k: CString => unsafe { Lua_setfield(L, LUA_GLOBALSINDEX, k) } }
		Lua_pushstring(L, config)
		withCString("DAEMON_CONFIG") { k: CString => unsafe { Lua_setfield(L, LUA_GLOBALSINDEX, k) } }

		/* 跑 chunk 一次：完成 setup（开总线/配置传感器/附着槽）并定义全局 daemon_tick */
		let st = Lua_loadfilex(L, chunk, CPointer<C_Char>())
		if (st != LUA_OK) {
			println("[daemon] chunk load error: ${luaErrorString(L)}")
			Lua_free(L)
			return -1i64
		}
		let setupStatus = Lua_pcall(L, 0, LUA_MULTRET, 0)
		if (setupStatus != LUA_OK) {
			println("[daemon] chunk setup error: ${luaErrorString(L)}")
			Lua_free(L)
			return -1i64
		}
		Lua_settop(L, 0)

		/* 逐拍循环：每拍 getglobal(daemon_tick)+pcall 采样一次；拍间用 Cangjie sleep——
		 * 在 M:N 运行时下 sleep 会让出绿色线程、不独占 schd-worker（D 方案关键，
		 * 区别于 chunk 内 ffi usleep 阻塞 worker 导致 worker 池耗尽的死锁）。 */
		withCString("daemon_tick") { tickName: CString =>
			while (!daemon_stop_requested(slot)) {
				unsafe {
					Lua_getglobal(L, tickName)
					let st = Lua_pcall(L, 0, LUA_MULTRET, 0)
					if (st != LUA_OK) {
						println("[daemon] tick error: ${luaErrorString(L)}")
					}
					Lua_settop(L, 0)
				}
				sleep(Duration.millisecond * interval_ms)
			}
		}

		/* H-07：stop 后、Lua_free 前，调用 chunk 定义的 daemon_cleanup()（若存在）
		 * 关闭守护打开的总线 fd——否则守护线程持有的 lua_State 长期泄漏 fd。
		 * daemon_probe 等无资源 chunk 未定义该函数，Lua_type==LUA_TNIL 跳过。
		 * 注意：sandbox_lua 中和/print 覆盖不影响本清理路径（不走全局 print）。 */
		withCString("daemon_cleanup") { cleanupName: CString =>
			unsafe {
				Lua_getglobal(L, cleanupName)
				if (Lua_type(L, -1) == LUA_TFUNCTION) {
					let st = Lua_pcall(L, 0, LUA_MULTRET, 0)
					if (st != LUA_OK) {
						println("[daemon] cleanup error: ${luaErrorString(L)}")
					}
				}
				Lua_settop(L, 0)
			}
		}

		let n = CPointer<Int32>(slot + SLOT_COUNT_OFF).read()
		Lua_free(L)
		return Int64(n)
	}
}

/* ---- chunk 路径寻址（P：任意位置运行；issue #19 支持多路径）----
 * 普通 Lua 硬件模块经 RobotStruct.cj 以 "${BOT4CJ_MODULE_PATH}/${mtName}.lua" 寻址；
 * 原实现把 chunk 列当字面路径直接 loadfilex（相对进程 CWD），编译产物换目录即找不到。
 * 统一为与普通硬件模块一致的 modulePath 基准：
 *   绝对路径（'/' 开头）                              → 原样
 *   已在模块目录树内（"./modules" 或 "modules" 前缀）→ 原样（兼容现有 SQL 写法）
 *   其余相对路径（如 lib/sensor_daemon.lua）           → 多路径按序探测（firstExistingModule）
 * modulePath 由调用方从 BOT4CJ_MODULE_PATH 取得（缺省 "./modules"），可为 ':' 分隔多路径。
 */
/* ---- issue #19：多模块路径按序查找第一个存在的文件 ----
 * BOT4CJ_MODULE_PATH 支持 ':' 分隔多个路径；依次探测 File 可读，命中即返回；
 * 全部不存在返回最后一个路径拼接（保持原有"文件不存在"加载报错语义）。 */
public func firstExistingModule(paths: String, rel: String): String {
	let parts = paths.split(":")
	var last = "${paths}/${rel}"
	for (p in parts) {
		if (p == "") { continue }
		let cand = "${p}/${rel}"
		try {
			let f = File(cand, OpenMode.Read)
			f.close()
			return cand
		} catch (_) {
			last = cand
		}
	}
	return last
}

public func resolveDaemonChunk(chunk: String, modulePath: String): String {
	if (chunk.startsWith("/")) {
		return chunk
	}
	if (chunk.startsWith(modulePath + "/")) {
		return chunk
	}
	/* 兼容不带 "./" 的旧写法：缺省 modulePath="./modules" 时结构脚本写
	 * 'modules/lib/xxx.lua' 也应原样（否则会被拼成 ./modules/modules/lib/xxx.lua）。 */
	let noDot = if (modulePath.startsWith("./")) {
		let rs = modulePath.toRuneArray()
		let arr = Array<Rune>(rs.size - 2, { i => rs[i + 2] })
		String(arr)
	} else {
		modulePath
	}
	if (chunk.startsWith(noDot + "/")) {
		return chunk
	}
	return firstExistingModule(modulePath, chunk)
}

/* ---- 守护硬件变量 ---- */
public class MtVars_Daemon <: MatrixVars_Hardware {
	public init(things!: (JsonValue) -> JsonValue,
			rise!: Option<() -> Unit> = None,
			free!: Option<() -> Unit> = None)
	{  super(things: things, rise: rise, free: free)  }

	/*
	 *  @Daemon
	 *   name    chunk;
	 *   sim0    lib/daemon_probe.lua;
	 *  @
	 */
	public static func Factory(defs: MatrixObject, i: Int64,
			_: HashMap<String, MatrixVars_Hardware>,
			registry: ArrayList<DaemonHolder>): MtVars_Daemon
	{
		let idxName = defs.indexOfCol(0, "name")
		let idxChunk = defs.indexOfCol(0, "chunk")
		let name = defs[i, idxName]
		let chunkRaw = MatrixVars_Hardware.getMt(defs, i, idxChunk)
		/* chunk 寻址：与普通 Lua 硬件模块一致，相对路径以 BOT4CJ_MODULE_PATH 为基准解析，
		 * 使编译产物可拷到任意位置运行（原实现字面路径相对 CWD） */
		let modulePath = getVariable("BOT4CJ_MODULE_PATH") ?? "./modules"
		let chunkPath = resolveDaemonChunk(chunkRaw, modulePath)
		println("Create a Daemon hard-Var: ${name}, chunk: ${chunkPath}")

		/* 单遍列扫描：收集 name/chunk 之外的列为配置串 "k=v;k=v" 注入 chunk
		 * （如 i2c/addr/interval），同时提取采样间隔 interval（ms，缺省 5，
		 * 供 daemon_body 逐拍 Cangjie sleep；解析与校验见 parseInterval）。
		 * 用 let 定型以便 rise 闭包安全捕获（规避捕获可变变量） */
		var cfgAcc = ""
		var ivAcc: Int64 = 5
		for (j in 0..defs.col) {
			let colName = defs[0, j]
			if (colName == "name" || colName == "chunk") { continue }
			let v = MatrixVars_Hardware.getMt(defs, i, j)
			cfgAcc = "${cfgAcc}${colName}=${v};"
			if (colName == "interval" && v != "-") {
				ivAcc = parseInterval(v, name, defs.getName(), i)
			}
		}
		let configStr = cfgAcc
		let intervalMs = ivAcc

		/* join 超时（P3）：正常退出 = stop 置位后最多再等一拍 sleep + tick 执行，
		 * 取 interval 5 倍并保底 2000ms，防守护 tick 长时间阻塞时 deactivate 挂死。
		 * 超时后放弃 join、保留 slot（防 UAF），由进程退出回收。 */
		let joinTimeoutMs = if (intervalMs * 5 > 2000) { intervalMs * 5 } else { 2000 }

		/* 分配并清零共享槽，初始化 mutex（offset 0）。malloc 失败（NULL）
		 * 立即抛错，杜绝后续 (slot+k).write 解引用空指针崩态 */
		let slot = unsafe { LibC.malloc<UInt8>(count: SLOT_SIZE) }
		if (slot.isNull()) {
			throw Exception("Daemon '${name}' failed to allocate shared slot (${SLOT_SIZE} bytes)")
		}
		unsafe {
			for (k in 0..SLOT_SIZE) { (slot + k).write(0u8) }
			_mutex_init(slot)
		}
		let holder = DaemonHolder(slot: slot, joinTimeoutMs: joinTimeoutMs)
		registry.add(holder)	/* 注册：deactivate 先统一置 stop 再 join，防饿死死锁 */

		/* 事件回调统一转调具名静态实现 playImpl/riseImpl/freeImpl——
		 * 此前三个大闭包内联于 Factory（~144 行难读难测），与 MtVars_Lua
		 * 已完成的同类重构（见 Lua.cj 构造函数注释）对齐。 */
		let daemon = MtVars_Daemon(
			things: { _: JsonValue => playImpl(holder, name) },
			rise: { => riseImpl(holder, name, chunkPath, configStr, intervalMs) },
			free: { => freeImpl(holder, name) }
		)
		return daemon
	}

	/* ---- interval 列解析与校验（P2/P3-1）----
	 * interval ≤ 0 会让 daemon_body 的 sleep(0) 空转，守护线程 100% CPU
	 * 忙循环且占满 schd-worker；解析失败/非数字亦须显式报错。
	 * 故：解析失败与非正值一律抛出带 表/行/列/值 上下文的异常，而非静默沿用。 */
	private static func parseInterval(iv: String, name: String, tabName: String, row: Int64): Int64 {
		let parsed = try {
			Int64.parse(iv)
		} catch (e: Exception) {
			throw IllegalArgumentException(
				"Daemon '${name}': column 'interval' value '${iv}' is not a valid integer (in table '${tabName}', row ${row}).")
		}
		if (parsed <= 0) {
			throw IllegalArgumentException(
				"Daemon '${name}': column 'interval' must be > 0 ms, got ${parsed} (in table '${tabName}', row ${row}). interval <= 0 causes a busy-loop that pins a CPU core.")
		}
		return parsed
	}

	/* ---- play 事件实现：主线程加锁读采样值 → JSON。值同时以标量键 v0..vN 暴露，
	 *      供别的硬件变量经引用机制读取（call_lua 只传标量、不传 JsonArray） ---- */
	private static func playImpl(holder: DaemonHolder, name: String): JsonValue {
		let ret = JsonObject()
		let arr = JsonArray()
		unsafe {
			_mutex_lock(holder.slot)
			let nvals = Int64(CPointer<Int32>(holder.slot + SLOT_NVALS_OFF).read())
			let count = Int64(CPointer<Int32>(holder.slot + SLOT_COUNT_OFF).read())
			var nv = nvals
			if (nv > SLOT_MAXVALS) { nv = SLOT_MAXVALS }
			for (k in 0..nv) {
				let v = CPointer<Float64>(holder.slot + SLOT_VALUES_OFF + 8 * k).read()
				arr.add(JsonFloat(v))
				ret.put("v${k}", JsonFloat(v))
			}
			_mutex_unlock(holder.slot)
			ret.put("status", JsonString("OK"))
			ret.put("count", JsonInt(count))
			ret.put("nvals", JsonInt(nvals))
			ret.put("values", arr)
			logD({ => "Daemon '${name}' play: count=${count} nvals=${nvals}" })
		}
		return ret
	}

	/* ---- rise 事件实现：spawn 守护线程（Cangjie 原生并发原语，运行时已附着）。
	 *      chunk/config CString 由守护线程连同 daemon_body 结果一起释放（P6/M4；
	 *      所有 return 路径都经 finally 释放） ---- */
	private static func riseImpl(holder: DaemonHolder, name: String, chunkPath: String,
			configStr: String, intervalMs: Int64): Unit {
		unsafe {
			let cstr = LibC.mallocCString(chunkPath)
			let cfg_cstr = LibC.mallocCString(configStr)
			let slot_p = holder.slot
			let f = spawn {
				var r = -1i64
				try { r = daemon_body(slot_p, cstr, cfg_cstr, intervalMs) }
				finally { LibC.free(cstr); LibC.free(cfg_cstr) }
				r
			}
			holder.future = Option<Future<Int64>>.Some(f)
			println("Daemon '${name}' spawned, config: ${configStr}")
		}
	}

	/* ---- free 事件实现：置停止标志 + future 带超时等待退出 + 销毁 mutex
	 *      （显式停止，见 issue #3）。
	 *      超过 joinTimeoutMs 未退出（守护 tick 长时间阻塞等）则放弃等待并跳过
	 *      slot 释放——守护线程仍可能在使用该槽 publish/读 stop，立即 destroy/free
	 *      会 use-after-free；保留 slot 交给进程退出时由 OS 回收，同步打印警告。 ---- */
	private static func freeImpl(holder: DaemonHolder, name: String): Unit {
		daemon_request_stop(holder.slot)
		if (let Some(f) <- holder.future) {
			try {
				let n = f.get(Duration.millisecond * holder.joinTimeoutMs)
				println("Daemon '${name}' joined, total publishes=${n}")
				releaseSlot(holder.slot)
			} catch (e: TimeoutException) {
				println("Daemon '${name}' not exited within ${holder.joinTimeoutMs}ms, abandoning slot (thread still running)")
			}
		} else {
			releaseSlot(holder.slot)
		}
	}

	/* ---- 销毁 mutex 并释放共享槽（freeImpl 两分支共用） ---- */
	private static func releaseSlot(slot: CPointer<UInt8>): Unit {
		unsafe {
			_mutex_destroy(slot)
			LibC.free(slot)
		}
	}
}
