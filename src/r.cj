/*
 *  机器人构成模块
 *  INFO(20260514-qing): 该模块确定机器人结构，为解耦考虑应该从解析出的矩阵对象中构建
 *  TODO(20260527-qing): 使脚本中的数值亦可从运行时确定
 */

package bot4cj
import std.io.*
import std.time.*
import std.random.*
import std.collection.*
import std.convert.*
import std.env.*
import std.process.*
import stdx.encoding.json.*
import ctype4cj.*
import luajit4cj.*
import mt2.*
import SQL4cj.*

/* ---- Lua 类型常量（luajit4cj 未导出，按 lua.h 取值；LUA_TTABLE=5 已由其提供）---- */
let LUA_TNUMBER: C_Int = 3		/* 数字（lua_tolstring 会将其原地转为字符串） */
let LUA_TSTRING: C_Int = 4		/* 字符串 */

/* ---- 调试转储开关：设置环境变量 BOT4CJ_VERBOSE 时，输出每次硬件调用的参数/结果转储 ----
 *  缺省静默，解决 call_lua/build_lua 每次调用刷屏（issue #5 清单 P3）；
 *  错误信息不经本函数，始终打印 */
func dumpLog(msg: String): Unit {
	if (Process.current.getEnv("BOT4CJ_VERBOSE").isSome()) {  println(msg)  }
}

/* ---- 读取 Lua 栈顶错误对象为字符串 ----
 *  lua_tolstring 对非 string/number 的值返回空指针，直接 toString() 是空指针解引用；
 *  先判型，非字符串对象返回类型说明（issue #5 清单 H5） */
func luaErrorString(L: lua_State): String {
	let t = unsafe { Lua_type(L, -1) }
	if (t == LUA_TSTRING) {
		let s = unsafe { Lua_tostring(L, -1) }
		return s.toString()
	}
	return "<non-string error object, Lua type ${t}>"
}

/* ---- 收紧 Lua 沙箱（issue #9 M1 可落地部分）----
 *  保留 os.getenv（模块路径）/ os.time|clock / dofile / require（HAL 的 ffi 依赖），
 *  中和可直接破坏宿主的入口：shell 执行（os.execute / io.popen）、进程退出（os.exit）、
 *  任意文件读写（io.open / io.lines / os.remove / os.rename）。
 *  各全局缺表时跳过对应组，不中断启动。 */
func sandbox_lua(L: lua_State): Unit {
	unsafe {
		let osKeys = ["execute", "exit", "remove", "rename"]
		let kos = LibC.mallocCString("os")
		Lua_getglobal(L, kos)
		if (Lua_type(L, -1) == LUA_TTABLE) {
			for (name in osKeys) {
				let kn = LibC.mallocCString(name)
				Lua_pushnil(L)
				Lua_setfield(L, -1, kn)
				LibC.free(kn)
			}
		}
		Lua_pop(L, 1)
		LibC.free(kos)

		let ioKeys = ["popen", "open", "lines"]
		let kio = LibC.mallocCString("io")
		Lua_getglobal(L, kio)
		if (Lua_type(L, -1) == LUA_TTABLE) {
			for (name in ioKeys) {
				let kn = LibC.mallocCString(name)
				Lua_pushnil(L)
				Lua_setfield(L, -1, kn)
				LibC.free(kn)
			}
		}
		Lua_pop(L, 1)
		LibC.free(kio)
	}
}

/*
 * ---------------- 硬件变量基类 ----------------
 *  接收3个lambda表达式，在回调函数中定义行为（）
 *  通过JsonValue这种通用的数据结构进行传值
 *  
 *  INFO*(20260517-qing): 因为析构器（终结器）的调用时间不确定，需要手动构造RAII机制
 *  TODO(20260519-qing): 考虑将@Action矩阵对象置为硬件变量的一种
 *  TODO*(20260529-qing): 增加微调器机制，通过不同的微调器对@Action进行微调
 */
open class MatrixVars_Hardware {

	/*  ---------------- 主初始化器 ----------------
	 *   输入三个回调函数，用json参数能够为多种硬件提供同一接口
	 *   在@Action矩阵中的每一列都是一个输入参数
	 *  --------------------------------------------  */
	public init(
	things!: (JsonValue) -> JsonValue,	/* 运行硬件或传感器 */
	rise!: Option<() -> Unit>,		/* 可选的硬件构造函数 */
	free!: Option<() -> Unit>) {		/* 可选的硬件析构函数 */

		this.things = things
		this.rise   = rise
		this.free   = free
	}


	/*
	 *  --------------------------------
	 *  事件回调，接收和返回JsonValue 这是整个硬件的主要事件
	 */
	private let things: (JsonValue) -> JsonValue	

	/* 召集事件，不接受参数  即硬件获取资源  */
	private let rise: Option<() -> Unit>

	/* 遣返事件，不接受参数  即硬件释放资源*/
	private let free: Option<() -> Unit>

	/*
	 *  -------------------------------- *
	 *  事件发生器  该方法会调用硬件，需要传入1个JsonValue参数  它返回1个JsonValue值
	 *
	 *  TODO(20260612-qing): 使用某种方式记录变量是否经过了初始化 
	 */
	public func play(input: JsonValue): JsonValue {  return things(input)  }

	/*
	 *  -------------------------------- *
	 *  伪初始化器  该方法会打开硬件，什么也不传入和返回
	 */

	public func build(): Unit {

		if (let Some(callback) <- rise) {  callback()  }
	}

	/* 
	 *  -------------------------------- *
	 *  伪解构器   该方法会关闭硬件，什么也不传入和返回
	 */
	public func destroy(): Unit {

		if (let Some(callback) <- free) {  callback()  }
	}

	/*
	 *  ---------------------------------- 
	 *  获得项目值。如果矩阵单元的原始值是占位符且不为标题行，
	 *  不为首行， 就递归地获取上一行的值
	 */
	public static func getMt(obj: MatrixObject, row: Int64, col: Int64): String
	{
		let raw = obj[row, col]
		if (raw == "-" && row > 1) {
			return getMt(obj, row - 1, col)
		}
		return raw
	}

	/*
	 * ----------------------------------
	 * 解析项目值，先获取矩阵单元的项目值————解析过占位符的值）————然后解析为需要的类型
	 */
	public static func parseMt<T>(obj: MatrixObject, row: Int64, col: Int64): T  where T <: Parsable<T>
	{	
		/* 先获取矩阵单元的原始值 */
		let raw = obj[row, col]

		/* 如果原始值为占位符且（非首行的）非标题行 */
		if      (raw == "-" &&   row > 1)  { return  parseMt<T>(obj, row-1, col)  }

		/* 原始值为占位符且为（非标题行的）首行 */
		else if (raw == "-" && !(row > 1)) {  return T.parse("0")  }

		/* 原始值并非占位符  */
		return T.parse(raw)
	}



	/* ---------------------------------- */
}


/*
 * Lua状态机 - 硬件变量
 *
 * TODO(20260612-qing): 提前创建Lua状态机，利用闭包进行引用储存
 *      在rise中申请的资源将在free中被释放。
 *
 *      我们将Lua状态机做成类成员存储，在原本的召集函数中进行初始化
 *      在解构函数中释放资源。
 * 
 */
class MtVars_Lua <: MatrixVars_Hardware {

	/*
	 *  构造函数 => 传入事件函数，硬件构造函数以及硬件解构函数
	 *
	 *  FIXME: 将构造函数设置为 private
	 */
	public init(things!: (JsonValue) -> JsonValue,
			rise!: Option<() -> Unit> = None,
			free!: Option<() -> Unit> = None

	) {  super(things: things, rise: rise, free: free)  }
	

	/*
	 *  工厂函数 => 运行指定Lua脚本，传入矩阵中的所有参数（元数据）
	 *
	 *  controller: 可选的控制器硬件变量（饿汉绑定）。
	 *  声明后本硬件变量的 call 事件变为两级调用：
	 *  先运行自己的 Lua 驱动，再把「元数据 ∪ Lua返回表」转发给 controller.play()
	 */
	public static func Factory(luapath: String, getMetadata: ()->JsonObject,
			controller!: Option<MatrixVars_Hardware> = None): MtVars_Lua
	{

		/* 创建LUA状态机对象 */
		let L: lua_State = unsafe {  Lua_init()  }

		/* 检查有没有创建成功？ */
		if ( unsafe { Lua_check(L) } == LUA_ERR) {
			throw IllegalMemoryException("Lua_check()")  }


		let mtVars_Lua = MtVars_Lua(

			/*
			 *  主要事件：调用该硬件的驱动脚本
			 *  合并两张表（json_obj），一张来自创建该硬件时的矩阵（元数据）
			 *  另一张是调用该硬件事件时传入的参数（ @Action ）
			 * 
			 *  其中前者是一些诸如I2C地址、SPI速率的硬件参数
			 *  后者是一些类似舵机旋转角度的实时参数
			 *
			 * TODO(20260825): 事先创建完所有ACTION的行，创建好每一步的参数
			 */
			things: { json: JsonValue =>

				/* 获取元数据 */
				let metadata = getMetadata()

				/*  从元数据（json_obj）进行深拷贝  */
				let obj = metadata
				obj.put("mode", JsonString("call"))

				/*  合并两张（json_obj）表（元数据和参数）  */
				let fields: HashMap<String, JsonValue> = json.asObject().getFields()
				for (k in fields.keys()) {
					let val = fields.get(k).getOrThrow()
					obj.put(k, val)
				}
				dumpLog("Lua scripts call parameters: ${obj.toString()}")

				/* 调用Lua解释器 */
				let res = call_lua(L, obj)

				dumpLog("Lua script call result: ${res.toString()}")

				/* ---- controller 转发：元数据 ∪ 自己Lua的返回表 ---- */
				if (let Some(ctrl) <- controller) {
					/* 重新收集元数据（skipCol 已跳过 controller 列） */
					let payload = getMetadata()
					let retFields: HashMap<String, JsonValue> = res.asObject().getFields()
					for (k in retFields.keys()) {
						payload.put(k, retFields.get(k).getOrThrow())
					}
					dumpLog("Forward to controller: ${payload.toString()}")

					let ctrl_res = ctrl.play(payload)
					dumpLog("Controller result: ${ctrl_res.toString()}")
					return ctrl_res
				}

				return res

			},

			/* 硬件构造方法：提供元数据（json_obj）  对该硬件进行初始化 */
			rise: { =>

				/*  在这里构建Lua状态机   TODO: 使用专用的异常  */
				if (build_lua(L, luapath) == false) {
					throw Exception("Failed to build Lua state from script: '${luapath}'. Please check if the file exists and is valid Lua code.")
				}


				/* 获取元数据 */
				let metadata = getMetadata()

				/* 从元数据进行深拷贝 */
				let obj = metadata

				/* 插入模式指令 （告知lua脚本这是在构建） */
				obj.put("mode", JsonString("build"))
				dumpLog("Lua scripts build parameters: ${obj.toString()}")

				/* 开始构建 */
				let res = call_lua(L, obj)

				dumpLog("Lua script build result: ${res.toString()}")
			},

			/*
			 *  硬件解构方法：传入元数据（json_obj|json_data）
			 *  然后使用Lua状态机对设备进行关闭（或者重置）
			 */
			free: { =>

				/* 获取元数据 */
				let metadata = getMetadata()

				/*  从元数据进行深拷贝  */
				let obj = metadata

				/*  插入模式指令  */
				obj.put("mode", JsonString("destroy"))
				dumpLog("Lua scripts destroy parameters: ${obj.toString()}")

				let res = call_lua(L, obj)

				dumpLog("Lua script destroy result: ${res.toString()}")
				/* ---- 在这里写就Lua状态机的解构 ---- */
				destroy_lua(L)

			}

		)


		/*
		 * --------------------------------
		 * 返回构造的硬件变量本体
		 */
		return mtVars_Lua
	}


	/*  构造Lua状态机  申请资源
	 *
	 *  NOTE(20260618-qing): 构建完毕会运行一次 */
	private static func build_lua(L: lua_State, luapath: String): Bool {
		unsafe {
			let filename_c = LibC.mallocCString(luapath)
			if (filename_c.isEmpty()) { throw IllegalMemoryException("LibC.mallocCString()")  }

			/*  加载Lua标准库（os/io等，HAL.lua 依赖；不再注册硬件cfunc）  */
			Lua_loadlib(L)
			sandbox_lua(L)	/* 中和 os.execute/io.popen 等宿主入口（issue #9 M1） */

			/* -------- 设置Lua状态机 -------- */
			var status =  Lua_loadfilex(L, filename_c, CPointer<C_Char>())
			LibC.free(filename_c)			

			if (status == LUA_OK) {
				var status = Lua_pcall(L, 0, LUA_MULTRET, 0)
				dumpLog("lua build status: ${status}")
				if (status == LUA_OK) { return true  }
			}

			/* -------- 从栈顶获取错误信息（判型防空指针，见 luaErrorString） -------- */
			println(luaErrorString(L))
			Lua_settop(L, 0)	/* 恢复栈，错误对象不滞留（issue #5 清单 H5） */

			return false
		}
	}

	/*
	 *  释放LUA状态机
	 *
	 *  NOTE(20260618-qing): 销毁之后该变量即废弃
	 */
	private static func destroy_lua(L: lua_State) {
		unsafe { Lua_free(L) }
	}

	/*
	 *  调用Lua脚本的方法
	 *
	 *  NOTE(20260618-qing): 每次调用之后会重置栈指针
	 */
	private static func call_lua(L: lua_State, json: JsonValue): JsonValue {
		let obj = json.asObject()
		let ret = JsonObject()
		unsafe {

			/* ---- 获取栈顶指针  ----*/
			let top  = Lua_gettop(L)

			/* ---- ---- */
			let mode = obj.get("mode").getOrThrow().asString().getValue()
			let cstr = LibC.mallocCString(mode)
			Lua_getglobal(L, cstr)
			LibC.free(cstr)

			/* ----在Lua状态机里 创建Lua表 ---- */				
			Lua_createtable(L, 0, 0)
			

			/* ---- 向Lua表中推入数据 ---- */
			let fields: HashMap<String, JsonValue> = obj.getFields()
			for (k in fields.keys()) {
				let val = fields.get(k).getOrThrow()
				if (val is JsonString) {
					let v = val.asString().getValue()
					let sk = LibC.mallocCString(k)
					let sv = LibC.mallocCString(v)
					Lua_pushstring(L, sv)
					Lua_setfield(L, -2, sk)
					LibC.free(sk)
					LibC.free(sv)
				}
				else if (val is JsonInt) {
					let v = val.asInt().getValue()
					let sk = LibC.mallocCString(k)
					let sv = Int64(v)
					Lua_pushinteger(L, sv)
					Lua_setfield(L, -2, sk)
					LibC.free(sk)
				}
				else if (val is JsonFloat) {
					let v = val.asFloat().getValue()
					let sk = LibC.mallocCString(k)
					Lua_pushnumber(L, v)
					Lua_setfield(L, -2, sk)
					LibC.free(sk)
				}
			}

			var status = Lua_pcall(L, 1, LUA_MULTRET, 0)
			dumpLog("lua status: ${status}")
			if (status == LUA_OK) {
				if (Lua_type(L, -1) == LUA_TTABLE) {
					/* ---- 栈顶是表  压入 nil 作为遍历的起始键 ---- */
					Lua_pushnil(L)
					while(Lua_next(L, -2) != 0) {
						/* ---- 此时栈：[表, 键, 值] ----
						 * Lua 手册警告：遍历期间对【键】调 lua_tolstring 会原地改写键值，
						 * 数字键将扰乱后续 lua_next；故键只接受 string，其余类型跳过。
						 * 值支持 string/number，不再因非法类型 throw 而跳过栈恢复 ---- */
						let keyType = Lua_type(L, -2)
						let valType = Lua_type(L, -1)
						if (keyType != LUA_TSTRING || (valType != LUA_TSTRING && valType != LUA_TNUMBER)) {
							dumpLog("Lua return field skipped: key type ${keyType}, value type ${valType}")
							Lua_pop(L, 1)	/* 弹出值，保留键供下一次 Lua_next */
							continue
						}
						let key = Lua_tostring(L, -2)
						let val = Lua_tostring(L, -1)
						if (valType == LUA_TNUMBER) {
							/* number 保真为 JsonFloat（此前一律字符串化，见 issue #10 类型失真项）；
							 * nan/inf 等不可解析时退回 JsonString */
							try {
								ret.put(key.toString(), JsonFloat(Float64.parse(val.toString())))
							} catch (e: Exception) {
								ret.put(key.toString(), JsonString(val.toString()))
							}
						}
						else {
							ret.put(key.toString(), JsonString(val.toString()))
						}
						Lua_pop(L, 1)
					}
				}
			}

			else if (status != LUA_OK) {
				println("Lua 错误详情: ${luaErrorString(L)}")
			}

			/* -------- 恢复Lua状态机 -------- */
			Lua_settop(L, top)
		}
		return ret
	}
}

/*  别名变量（硬件类型）
 *  这种变量用于给某个参数取一个更简单的别名  它的事件返回（JsonString）将作为新的矩阵项目值
 */
class MtVars_Alias <: MatrixVars_Hardware {
	public init(things!: (JsonValue) -> JsonValue,
			rise!: Option<() -> Unit> = None,
			free!: Option<() -> Unit> = None  )
	{  super(things: things, rise: rise, free: free)  }

	public static func Factory(AliasDefs: MatrixObject, i: Int64,
			_: HashMap<String, MatrixVars_Hardware>): MtVars_Alias
	{
		let idxName = AliasDefs.indexOfCol(0, "name")
		let idxAlias= AliasDefs.indexOfCol(0, "alias")

		let name = AliasDefs[i, idxName]
		let alias= getMt(AliasDefs, i, idxAlias)

		println("Create a Alias vars: ${name}, witch means ${alias}")
		let mtvars_alias = MtVars_Alias(things: {_: JsonValue =>
			let str = JsonString(alias)	/*  直接返回JsonString（alias）*/
			return str
		})

		return mtvars_alias
	}
}

/*
 * ---------------- 守护线程硬件变量（@Daemon） ----------------
 *  用 Cangjie spawn 原语起守护线程（运行时已附着，区别于 pthread4cj 裸线程——
 *  后者在 foreign 线程上跑 Cangjie @C 代码必崩，已 PoC 证伪）。线程上创建
 *  【独立 lua_State】，loadfilex 采样 chunk 一次 + pcall 一次（chunk 内 while 循环
 *  轮询停止标志）。线程与其 lua_State 1:1 独占，主线程绝不触碰该状态机。
 *
 *  IPC：共享内存槽 daemon_slot_t（布局见 modules/lib/pthread.lua，两侧严格一致），
 *  守护侧 Lua 经 pthread.lua 的 publish 写值（mutex 保护），主线程侧 play 经
 *  foreign pthread_mutex 加锁读取，防撕裂。
 */

/* ---- 共享槽 daemon_slot_t 布局偏移（必须与 modules/lib/pthread.lua 一致）---- */
let SLOT_COUNT_OFF: Int64 = 64		/* int32：publish 次数 */
let SLOT_NVALS_OFF: Int64 = 68		/* int32：本次值个数 */
let SLOT_VALUES_OFF: Int64 = 72		/* double[16]：采样值 */
let SLOT_STOP_OFF: Int64 = 200		/* uint8：停止标志 */
let SLOT_SIZE: Int64 = 208
let SLOT_MAXVALS: Int64 = 16

/* ---- libc pthread_mutex（直接 foreign 声明；libc 已链接，不需 pthread4cj）---- */
foreign func pthread_mutex_init(m: CPointer<UInt8>, attr: CPointer<Unit>): Int32
foreign func pthread_mutex_lock(m: CPointer<UInt8>): Int32
foreign func pthread_mutex_unlock(m: CPointer<UInt8>): Int32
foreign func pthread_mutex_destroy(m: CPointer<UInt8>): Int32

/* ---- 可变状态持有者：rise/free 闭包捕获此 let 引用并改其字段，
 *      规避 Cangjie「lambda 捕获可变变量」限制 ---- */
class DaemonHolder {
	public let slot: CPointer<UInt8>
	public var future: Option<Future<Int64>>
	public init(slot!: CPointer<UInt8>) {
		this.slot = slot
		this.future = None
	}
}

/* ---- 守护线程体（spawn 绿色线程上运行）：建私有 lua_State，注入槽地址+配置，
 *      先跑 chunk 一次完成 setup 并定义全局 daemon_tick，随后逐拍驱动 ---- */
public func daemon_body(slot: CPointer<UInt8>, chunk: CString, config: CString, interval_ms: Int64): Int64 {
	unsafe {
		let L = Lua_init()
		if (Lua_check(L) == LUA_ERR) { return -1i64 }
		Lua_loadlib(L)
		sandbox_lua(L)	/* 中和 os.execute/io.popen 等宿主入口（issue #9 M1） */

		/* 注入共享槽地址（整数）与配置串（"k=v;k=v"）为 Lua 全局 */
		Lua_pushinteger(L, Int64(slot.toUIntNative()))
		Lua_setfield(L, LUA_GLOBALSINDEX, LibC.mallocCString("DAEMON_SLOT_ADDR"))
		Lua_pushstring(L, config)
		Lua_setfield(L, LUA_GLOBALSINDEX, LibC.mallocCString("DAEMON_CONFIG"))

		/* 跑 chunk 一次：完成 setup（开总线/配置传感器/附着槽）并定义全局 daemon_tick */
		let st = Lua_loadfilex(L, chunk, CPointer<C_Char>())
		if (st != LUA_OK) {
			println("[daemon] chunk load error: ${luaErrorString(L)}")
			Lua_free(L)
			return -1i64
		}
		var pcs = Lua_pcall(L, 0, LUA_MULTRET, 0)
		if (pcs != LUA_OK) {
			println("[daemon] chunk setup error: ${luaErrorString(L)}")
			Lua_free(L)
			return -1i64
		}
		Lua_settop(L, 0)

		/* 逐拍循环：每拍 getglobal(daemon_tick)+pcall 采样一次；拍间用 Cangjie sleep——
		 * 在 M:N 运行时下 sleep 会让出绿色线程、不独占 schd-worker（D 方案关键，
		 * 区别于 chunk 内 ffi usleep 阻塞 worker 导致 worker 池耗尽的死锁）。 */
		let tickName = LibC.mallocCString("daemon_tick")
		while ((slot + SLOT_STOP_OFF).read() == 0u8) {
			Lua_getglobal(L, tickName)
			pcs = Lua_pcall(L, 0, LUA_MULTRET, 0)
			if (pcs != LUA_OK) {
				println("[daemon] tick error: ${luaErrorString(L)}")
			}
			Lua_settop(L, 0)
			sleep(Duration.millisecond * interval_ms)
		}

		let n = CPointer<Int32>(slot + SLOT_COUNT_OFF).read()
		Lua_free(L)
		return Int64(n)
	}
}

/* ---- 守护硬件变量 ---- */
class MtVars_Daemon <: MatrixVars_Hardware {
	public init(things!: (JsonValue) -> JsonValue,
			rise!: Option<() -> Unit> = None,
			free!: Option<() -> Unit> = None)
	{  super(things: things, rise: rise, free: free)  }

	/*
	 *  @Daemon
	 *   name    chunk;
	 *   sim0    modules/lib/daemon_probe.lua;
	 *  @
	 */
	public static func Factory(defs: MatrixObject, i: Int64,
			_: HashMap<String, MatrixVars_Hardware>,
			registry: ArrayList<DaemonHolder>): MtVars_Daemon
	{
		let idxName = defs.indexOfCol(0, "name")
		let idxChunk = defs.indexOfCol(0, "chunk")
		let name = defs[i, idxName]
		let chunkPath = MatrixVars_Hardware.getMt(defs, i, idxChunk)
		println("Create a Daemon hard-Var: ${name}, chunk: ${chunkPath}")

		/* 收集 name/chunk 之外的列为配置串 "k=v;k=v"，注入 chunk（如 i2c/addr/interval） */
		var cfgAcc = ""
		for (j in 0..defs.col) {
			let colName = defs[0, j]
			if (colName == "name" || colName == "chunk") { continue }
			let v = MatrixVars_Hardware.getMt(defs, i, j)
			cfgAcc = "${cfgAcc}${colName}=${v};"
		}
		let configStr = cfgAcc

		/* 提取采样间隔（ms）供 daemon_body 逐拍 Cangjie sleep；缺省 5ms。
		 * 用 let 定型以便 rise 闭包安全捕获（规避捕获可变变量） */
		var ivAcc: Int64 = 5
		for (j in 0..defs.col) {
			if (defs[0, j] == "interval") {
				let iv = MatrixVars_Hardware.getMt(defs, i, j)
				if (iv != "-") { ivAcc = Int64.parse(iv) }
			}
		}
		let intervalMs = ivAcc

		/* 分配并清零共享槽，初始化 mutex（offset 0） */
		let slot = unsafe { LibC.malloc<UInt8>(count: SLOT_SIZE) }
		unsafe {
			for (k in 0..SLOT_SIZE) { (slot + k).write(0u8) }
			pthread_mutex_init(slot, CPointer<Unit>())
		}
		let holder = DaemonHolder(slot: slot)
		registry.add(holder)	/* 注册：deactive 先统一置 stop 再 join，防饿死死锁 */

		let daemon = MtVars_Daemon(
			/* play：主线程加锁读采样值 → JSON。值同时以标量键 v0..vN 暴露，
			 *       供别的硬件变量经引用机制读取（call_lua 只传标量、不传 JsonArray） */
			things: { _: JsonValue =>
				let ret = JsonObject()
				let arr = JsonArray()
				unsafe {
					pthread_mutex_lock(holder.slot)
					let nvals = Int64(CPointer<Int32>(holder.slot + SLOT_NVALS_OFF).read())
					let count = Int64(CPointer<Int32>(holder.slot + SLOT_COUNT_OFF).read())
					var nv = nvals
					if (nv > SLOT_MAXVALS) { nv = SLOT_MAXVALS }
					for (k in 0..nv) {
						let v = CPointer<Float64>(holder.slot + SLOT_VALUES_OFF + 8 * k).read()
						arr.add(JsonFloat(v))
						ret.put("v${k}", JsonFloat(v))
					}
					pthread_mutex_unlock(holder.slot)
					ret.put("status", JsonString("OK"))
					ret.put("count", JsonInt(count))
					ret.put("nvals", JsonInt(nvals))
					ret.put("values", arr)
					dumpLog("Daemon '${name}' play: count=${count} nvals=${nvals}")
				}
				return ret
			},
			/* rise：spawn 守护线程（Cangjie 原生并发原语，运行时已附着） */
			rise: { =>
				unsafe {
					let cstr = LibC.mallocCString(chunkPath)
					let cfg_cstr = LibC.mallocCString(configStr)
					let slot_p = holder.slot
					let f = spawn { daemon_body(slot_p, cstr, cfg_cstr, intervalMs) }
					holder.future = Option<Future<Int64>>.Some(f)
					println("Daemon '${name}' spawned, config: ${configStr}")
				}
			},
			/* free：置停止标志 + future.get() 等待退出 + 销毁 mutex（显式停止，见 issue #3） */
			free: { =>
				unsafe {
					(holder.slot + SLOT_STOP_OFF).write(1u8)
					if (let Some(f) <- holder.future) {
						let n = f.get()
						println("Daemon '${name}' joined, total publishes=${n}")
					}
					pthread_mutex_destroy(holder.slot)
					LibC.free(holder.slot)
				}
			}
		)
		return daemon
	}
}

/* 机器人结构类
 * 
 * 机器人结构是动态的，从脚本中解析的 
 * TODO(20260514-qing): 调整为输入MatrixObject
 * TODO(20260515-qing): 需要重写一遍硬件类
 * TODO(20260518-qing): 使用神经网络RNN直接根据动作+传感器脚本生成下一步动作
 * TODO(20260527-qing): 增加硬件模块行为脚本
 * TODO*(20260527-qing): 为@Action表演矩阵对象增加位置指示器，以增量行动
 *
 * INFO(20260826-qing): 机器人结构类对象，接受输入流，随后逐个解析存入链表
 */
class RobotStruct {

	/* -------- 存放解析结果和创建的变量 -------- */
	private let C = LinkedList<MatrixObject>()
	/* -------- 守护 holder 注册表：deactive 先统一置 stop 再 join（防 worker 饿死死锁）-------- */
	private let daemonHolders = ArrayList<DaemonHolder>()
	private let M = HashMap<String, MatrixVars_Hardware>()
	/* 硬件变量声明序序列：active/deactive 按声明序 build/destroy
	 * （HashMap 遍历序未定义，而 I2C→PCA9685 等 fd 依赖要求声明序） */
	private let hwSeq = ArrayList<MatrixVars_Hardware>() 

	/* -------- 安全添加硬件变量（检查重复键） -------- */
	private func addHardwareVar(name: String, hw: MatrixVars_Hardware) {
		if (let Some(_) <- M.get(name)) {
			throw IllegalArgumentException("Duplicate hardware variable name: '${name}'")
		}
		M[name] = hw
		hwSeq.add(hw)
	}

	/*
	 *  注册一张 @Alias 矩阵中的所有别名变量
	 *
	 *  session: 动作脚本侧注册时传入本次 run 的会话集合——
	 *  同一动作脚本内重复定义抛错；与结构脚本同名则覆盖并打日志。
	 *  None 表示结构脚本侧注册，重名直接抛错（addHardwareVar 原有行为）。
	 */
	private func registerAliasMatrix(matrix: MatrixObject, session: Option<HashSet<String>>) {
		let idxName = matrix.indexOfCol(0, "name")
		for (i in 1..matrix.size) {
			let name = matrix[i, idxName]
			let aliasVar = MtVars_Alias.Factory(matrix, i, M)
			if (let Some(set) <- session) {
				if (set.contains(name)) {
					throw IllegalArgumentException("Duplicate alias name '${name}' within the action script")
				}
				set.add(name)
				if (let Some(_) <- M.get(name)) {
					println("Alias '${name}' defined in action script overrides the structure definition")
				}
				M[name] = aliasVar
			}
			else {
				addHardwareVar(name, aliasVar)
			}
		}
	}

	/*
	 *  使用矩阵脚本驱动机器人
	 * 
	 *  不行就将矩阵脚本转化为bot脚本吧
	 */
	public init(input: InputStream) {
		readSQL(input, C)
		createHardVars()
	}

	/* -------- 激活所有硬件变量 -------- */
	public func  active(): Unit {
		for (item in hwSeq) {
			item.build()
		}
	}

	/*
	 *  消除所有硬件变量
	 * 
	 *  INFO(20260517-qing): 它需要以倒序方式进行清除
	 */
	public func deactive(): Unit {
		/* P1 防死锁：先给【所有】守护置 stop，再统一 join。
		 * 否则逐个 stop+get 时，若先 join 一个被 worker 池饿死的守护，其余守护
		 * （stop 未置位）仍独占 worker → 饿死者永不运行 → get() 永久阻塞。
		 * 全部置 stop 后：运行中的守护退出释放 worker，饿死者随后拿到 worker 即见 stop 退出。 */
		for (h in daemonHolders) {
			unsafe { (h.slot + SLOT_STOP_OFF).write(1u8) }
		}
		let items = hwSeq.toArray()
		for (i in items.size-1..=0:-1) {
			items[i].destroy()
		}
	}

	/* -------- 执行@Action矩阵中的内容 -------- */
	public func run(input: InputStream): Unit {
		let AC = LinkedList<MatrixObject>()
		readMatrix(input, AC)

		/* ---- 注册动作脚本中内联的 @Alias（同名时覆盖结构脚本的定义） ---- */
		let session = HashSet<String>()
		for (matrix in AC) {
			if (matrix.getName().trimAscii() == "Alias") {
				registerAliasMatrix(matrix, Some(session))
			}
		}

		run_drl_action(AC)
	}

	/*
	 *  储存整个矩阵变量表
	 * 
	 *  NOTE(20260517-qing): 使用完毕要关闭输出流
	 */
	public func save(out: OutputStream): Unit {
		let ms = MatrixSaver(out)
		ms.save(C)
	}

	/*
	 *  阅读矩阵脚本
	 * 
	 *  TODO(20260504-qing): 使用矩阵脚本存储神经网络模型
	 */
	static private func readMatrix(file: InputStream, C: LinkedList<MatrixObject>){
		let sr = StringReader<InputStream>(file)
		let parser =  MatrixParser(sr)
		while (true) {
			if (let Some(O) <- parser.parse()) {
				let n = O.getName();
				println(n)
				C.addLast(O)  }
			else { break }
		}
	}

	static private func readSQL(input: InputStream, C: LinkedList<MatrixObject>) {
		let sr = StringReader<InputStream>(input)
		let tkns = Lexer.parseAll(sr)
		let eves = Parser.parseAll(tkns)
		for (eve in eves) {
			match (eve) {
				case CREATE_TABLE(ev) =>
					var mt = MatrixObject()
					for (ch in ev.tableName) {
						mt.addRune(Rune(ch))
					}
					mt.submitName()
					for (col in ev.tableColumns) {

						match (col._type) {
							case _String => 
								for (ch in col.name) {
									mt.addRune(Rune(ch))
								}
								mt.submitItem()
							case _ => throw Exception("Only String is Valid")
						}

					}
					mt.submitLine(0)
					C.addLast(mt)

				case INSERT_TABLE(ev) =>

					C.forEach({item =>

						if (ev.targetTabName == item.getName()) {

							println("{${ev.targetTabName}}")

							for (row in ev.tableRows) {
								/* ---- INSERT 值列与表头逐列匹配；缺列/重复列/未知列
								 * ---- 会使矩阵单元静默错位（动作打到错误舵机），显式报错 ---- */
								for (i in 0..item.col) {
									var matched = 0
									for (col in row) {
										if (col.columnName == item[0, i]) {
											matched += 1
											if (matched > 1) {
												throw IllegalArgumentException("INSERT INTO ${ev.targetTabName}: duplicate column '${col.columnName}'")
											}
											for (ch in col.value) {
												item.addRune(Rune(ch))
											}
											item.submitItem()
										}
									}
									if (matched == 0) {
										throw IllegalArgumentException("INSERT INTO ${ev.targetTabName}: column '${item[0, i]}' is missing in an INSERT row")
									}
								}
								for (col in row) {
									var known = false
									for (i in 0..item.col) {
										if (col.columnName == item[0, i]) { known = true; break }
									}
									if (!known) {
										throw IllegalArgumentException("INSERT INTO ${ev.targetTabName}: unknown column '${col.columnName}'")
									}
								}
								item.submitLine(0)
							}
						}
					})

				case _ => throw Exception("Unsupported sql command")
			}
		}
	}

	/*
	 *  创建硬件变量字典
	 * 
	 *  TODO(20260515-qing): 解耦合  
	 *  FIXME(20260518-qing): 在插入哈希表之前如果有已经存在的键值，要释放它的资源
	 */
	private func createHardVars()
	{

		for (matrix in C) {
		let MtName = matrix.getName()

		/* ---- 【特殊的】Alias别名硬件
			 * ---- */
			if (MtName == "Alias") {
				registerAliasMatrix(matrix, None)
			}


			/* ---- [特殊的] Action矩阵
			 * ---- */
			else if (MtName == "Action") {
				;
			}

			/* ---- 【特殊的】Daemon 守护线程硬件 ---- */
			else if (MtName == "Daemon") {
				let idxName = matrix.indexOfCol(0, "name")
				for (i in 1..matrix.size) {
					let name = matrix[i, idxName]
					addHardwareVar(name, MtVars_Daemon.Factory(matrix, i, M, daemonHolders))
				}
			}

			/* ---- 【通用的】Lua脚本硬件 ---- */
			else if (matrix.size > 0) {
				let idxName = matrix.indexOfCol(0, "name")

				/* ---- 手动扫描标题行，寻找可选的 controller 列 ---- */
				var idxCtrl: Int64 = -1
				for (j in 0..matrix.col) {
					if (matrix[0, j] == "controller") { idxCtrl = j; break }
				}

				/* ---- 从环境变量 BOT4CJ_MODULE_PATH 获取模块路径，默认为 ./modules ---- */
				let modulePath = Process.current.getEnv("BOT4CJ_MODULE_PATH") ?? "./modules"
				let scriptPath = "${modulePath}/${MtName}.lua"

				for (i in 1..matrix.size ) {
					let name = matrix[i, idxName]

					/* ---- 解析该行的 controller 引用（支持 - 占位符继承） ---- */
					var ctrlOpt: Option<MatrixVars_Hardware> = None
					if (idxCtrl >= 0) {
						let ctrlName = MatrixVars_Hardware.getMt(matrix, i, idxCtrl)
						if (ctrlName != "-") {
							let ctrlOptHV = M.get(ctrlName)
							if (ctrlOptHV.isNone()) {
								throw IllegalArgumentException(
									"Hardware variable '${name}' declares controller '${ctrlName}', but it is not defined yet. The controller must be defined before the matrix that references it.")
							}
							ctrlOpt = ctrlOptHV.getOrThrow()
						}
					}

					/* ---- 元数据闭包：跳过 controller 列，避免误当作引用 play ---- */
					let skipCol = idxCtrl	/* lambda 不得捕获可变变量 */
					addHardwareVar(name, MtVars_Lua.Factory(scriptPath, {=>
							this._getMetadata(matrix, i, skipCol: skipCol)
					}, controller: ctrlOpt))
				}
		}
		}
	}


	/* -------- 在矩阵对象的容器中寻找目标 -------- */
	private static func findMt(ll: LinkedList<MatrixObject>, name: String): Option<MatrixObject>
	{
		for (item in ll) {
			var target  = item.getName()
			target = target.trimAscii() // ???
			if (name == target) {
				return item  }
		}

		return None
	}

	/* -------- 使用drl微调动作，使用RNN生成动作流 -------- */
	private func run_drl_action(AC: LinkedList<MatrixObject>) {
		let ActionDefsOpt = findMt(AC, "Action")
		if (ActionDefsOpt.isNone()) {
			throw IllegalArgumentException("No @Action matrix found in script. Please define action matrix in your .mt file.")
		}
		let ActionDefs = ActionDefsOpt.getOrThrow()	/* MatrixObject */

		/* 按标题行的列顺序收集设备名，保证执行顺序与脚本列序一致
		 * （例如把 Timer(Speaker) 列写在最后，它就会最后执行，见 issue #12） */
		let order = ArrayList<String>()
		for (j in 0..ActionDefs.col) {
			let name_HV = ActionDefs[0, j]
			let arr = name_HV.split(".")
			if (arr.size != 2) {
				throw IllegalArgumentException("Action column is not valid")  }
			let name_dev = arr[0]
			if (!order.contains(name_dev)) {
				order.add(name_dev)  }
		}

		for (i in 1..ActionDefs.size) {
			let set =JsonObject()		/* 每个硬件变量的参数集合 */
			for (j in 0..ActionDefs.col) {
				parse_action_matrixObject(set, ActionDefs, i, j)
			}

			/* -------- 执行一行 -------- */
			for (name_dev in order) {
				let hvOpt = M.get(name_dev)
				if (hvOpt.isNone()) {
					throw IllegalArgumentException("Hardware variable '${name_dev}' is used in @Action but not defined in hardware declaration section.")
				}
				let hv = hvOpt.getOrThrow()
				let paramsOpt = set.get(name_dev)
				if (paramsOpt.isNone()) {
					throw IllegalArgumentException("Parameter for hardware variable '${name_dev}' is missing in action row ${i}.")
				}
				let params: JsonValue = paramsOpt.getOrThrow()
				let _: JsonValue = hv.play(params)
			}


		}
	}

	/* -------- 解析@Action矩阵对象 -------- */
	private func parse_action_matrixObject(set: JsonObject, ActionDefs: MatrixObject,
			i: Int64, j: Int64) {
		let name_HV = ActionDefs[0, j]	/* 获取硬件变量名 FIXME:  该名称不得使用占位符 且不重复 */
		let arr = name_HV.split(".")
		if (arr.size != 2) {
			throw IllegalArgumentException("Action column is not valid")  }
		let name_dev = arr[0]
		var name_param = arr[1]

		var val_fp64 = MatrixVars_Hardware.parseMt<Float64>(ActionDefs, i, j)

		let AliasHV = M.get(name_param)		/* 可能的参数别名转换 */
		if (let Some(aliasHV) <- AliasHV) {
			let ret = aliasHV.play(JsonObject())
			let alias = ret.asString().getValue()
			name_param = alias
		}

		var set_params: JsonObject	/* 设置或者取得属于该硬件变量的参数 */
		if (let Some(obj_) <- set.get(name_dev)) {
			set_params = obj_.asObject()  }
		else {
			set_params = JsonObject()
			set.put(name_dev, set_params)  }

		set_params.put(name_param, JsonFloat(val_fp64))	/* 设置一个该硬件变量的参数 */
	}

	/*
	 *  skipCol: 收集元数据时跳过的列下标（-1 表示不跳过）
	 *  controller 列的值是控制器硬件变量的名字，既不是字面元数据，
	 *  也不应在收集阶段被 play（转发发生在 things 回调里）
	 */
	private func _getMetadata(matrix: MatrixObject, i: Int64, skipCol!: Int64 = -1): JsonObject {
		let obj = JsonObject()
		let idxName = matrix.indexOfCol(0, "name")
		let name = matrix[i, idxName]
		for (j in 0..matrix.col) {
			let colName = matrix[0, j]
			/* ---- 无法继承的 "-" 占位符（整列皆 "-" 时递归止于首行）归一为 "0"，
			 * ---- 与 parseMt 的既有约定对齐，避免 "-" 泄漏进元数据与转发载荷 ---- */
			var value = MatrixVars_Hardware.getMt(matrix, i, j)
			if (value == "-") { value = "0" }
			/* ---- ----
			 * ---- FIXME: 加入点号别名的检索逻辑 ----
			 * ---- ---- */
			if (j == idxName || j == skipCol) { continue  } /* 自身调用警告 */
			if (let Some(mt) <- M.get(value)) {
				/* ---- ----
				 * ---- 存在该名称的变量，传入空对象参数，并求取返回值
				 * ---- ---- */
				let json = JsonObject()
				let res = mt.play(json).asObject()
				let fields: HashMap<String, JsonValue> = res.getFields()
				for (k in fields.keys()) {
					let val = fields.get(k).getOrThrow()
					obj.put(k, val)
				}
					
			}
			else {
				obj.put(colName, JsonString(value))
			}
		}

		return obj
		
	}


}


