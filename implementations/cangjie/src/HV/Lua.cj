/*
 *  Lua状态机 - 硬件变量（自 RobotStruct.cj 迁出）
 *
 *  Lua 状态机在工厂中提前创建，作为实例状态存储；
 *  rise 中申请的资源（加载脚本/初始化）将在 free 中被释放。
 *
 */

package bot4cj.HV
import std.collection.*
import std.sort.*
import stdx.encoding.json.*
import ctype4cj.*
import luajit4cj.*

/* ---- Lua 类型常量与取值/压栈 API 由 luajit4cj 提供（1.0.1 起导出，P7/M5 补齐） ---- */

/* ---- H-03：数组进 / 递归表出 需要的两个 C 符号（luajit4cj 未导出，本地补声明） ---- */
@C
foreign func lua_rawseti(L: lua_State, index: C_Int, n: C_LongLong): Unit
@C
foreign func lua_pushvalue(L: lua_State, index: C_Int): Unit

/* ---- 读取 Lua 栈顶错误对象为字符串 ----
 *  lua_tolstring 对非 string/number 的值返回空指针，直接 toString() 是空指针解引用；
 *  先判型：string/number 原样转串（lua_tolstring 会把数字原地转字符串），
 *  其余对象返回类型说明（issue #5 清单 H5） */
public func luaErrorString(L: lua_State): String {
	let t = unsafe { Lua_type(L, -1) }
	if (t == LUA_TSTRING || t == LUA_TNUMBER) {
		let s = unsafe { Lua_tostring(L, -1) }
		return s.toString()
	}
	return "<non-string error object, Lua type ${t}>"
}

/* ---- FFI C 字符串作用域辅助 ----
 *  malloc 失败即抛（杜绝空指针传入 Lua C API）；body 无论正常返回还是抛异常，
 *  finally 都会释放。此前 mallocCString/free 手工配对在本文件与 Daemon.cj
 *  重复约 18 处，漏 free / 提前 free 均只能靠肉眼审查。 */
func withCString<T>(s: String, body: (CString) -> T): T {
	let cs = unsafe { LibC.mallocCString(s) }
	if (cs.isNull()) { throw IllegalMemoryException("LibC.mallocCString()") }
	try {
		return body(cs)
	} finally {
		unsafe { LibC.free(cs) }
	}
}

/* ---- 探测 Lua 全局变量类型（getglobal + type + pop，栈深不变）----
 *  用于判断驱动是否定义了可选入口（read / destroy）。 */
func luaGlobalType(L: lua_State, name: String): C_Int {
	withCString(name) { cn: CString =>
		unsafe {
			Lua_getglobal(L, cn)
			let tp = Lua_type(L, -1)
			Lua_pop(L, 1)
			tp
		}
	}
}

/* ---- 收紧 Lua 沙箱（issue #9 M1 可落地部分）----
 *  保留 os.getenv（模块路径）/ os.time|clock / dofile / require（HAL 的 ffi 依赖），
 *  中和可直接破坏宿主的入口：shell 执行（os.execute / io.popen）、进程退出（os.exit）、
 *  任意文件读写（io.open / io.lines / io.input / io.output / os.remove / os.rename；
 *  io.input/io.output 在 LuaJIT 内部直调 fopen、不经过 io.open，须单独中和）。
 *  各全局缺表时跳过对应组，不中断启动。 */
public func sandbox_lua(L: lua_State): Unit {
	let groups = [
		("os", ["execute", "exit", "remove", "rename"]),
		("io", ["popen", "open", "lines", "input", "output"]),
	]
	for ((tab, keys) in groups) {
		withCString(tab) { kt: CString =>
			unsafe {
				Lua_getglobal(L, kt)
				if (Lua_type(L, -1) == LUA_TTABLE) {
					for (name in keys) {
						withCString(name) { kn: CString =>
							unsafe {
								Lua_pushnil(L)
								Lua_setfield(L, -2, kn)	/* 表在 -2：pushnil 后值在栈顶，-1 会索引 nil 致 PANIC */
							}
						}
					}
				}
				Lua_pop(L, 1)
			}
		}
	}
}

public class MtVars_Lua <: MatrixVars_Hardware {

	/* 顶层调用深度计数：只在外层 .mt 直接调用的原子处打印结果，
	 * 避免被 controller 转发的嵌套 Lua 调用重复输出。
	 * 约束（P：单线程）：非同步静态计数，动作路径（RobotStruct.cj play）串行执行，
	 * 不得引入并发访问；@Daemon 守护线程持独立 lua_State、不经本变量。 */
	private static var topDepth = 0

	/*
	 *  私有构造函数：把 Lua 状态机、脚本路径、元数据收集器与 controller 引用
	 *  固化为调用上下文，事件回调统一转调静态实现方法 callImpl/readImpl/
	 *  riseImpl/freeImpl（闭包只捕获构造参数，不引用 this——Cangjie 限制：
	 *  super 传递的回调不得在成员初始化前访问实例方法）。
	 *
	 *  （此前 Factory() 内联三个大闭包，183 行难读难测；抽成具名实现后职责单一。）
	 *  回调在 build/play/destroy 期才被调用，静态实现方法不受实例构造时序影响。
	 */
	private init(L: lua_State, luapath: String, getMetadata: () -> JsonObject,
			controller: Option<MatrixVars_Hardware>) {
		super(
			things: { json: JsonValue => MtVars_Lua.callImpl(L, luapath, getMetadata, controller, json) },
			rise: Some({ => MtVars_Lua.riseImpl(L, luapath, getMetadata) }),
			free: Some({ => MtVars_Lua.freeImpl(L, luapath, getMetadata) }),
		)
		this.readCb = Some({ => MtVars_Lua.readImpl(L, getMetadata) })
	}

	private let readCb: Option<() -> JsonValue>

	public override func read(): JsonValue {
		if (let Some(cb) <- this.readCb) { return cb() }
		return super.read()
	}


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


		/* 以私有构造构建硬件变量：事件回调统一转调实例方法 doCall/doRead/doRise/doFree */
		return MtVars_Lua(L, luapath, getMetadata, controller)
	}

	/*
	 *  call 事件实现：调用该硬件的驱动脚本。
	 *  合并两张表（json_obj）：创建时矩阵的元数据 + @Action 传入的实时参数。
	 *  controller 转发：元数据 ∪ 自己 Lua 的返回表 交给 controller.play()。
	 *  外层（topDepth==0）才把结果直出屏幕，避免被 controller 转发的嵌套调用重复打印。
	 */
	private static func callImpl(L: lua_State, luapath: String, getMetadata: () -> JsonObject,
			controller: Option<MatrixVars_Hardware>, json: JsonValue): JsonValue {
		let top = (MtVars_Lua.topDepth == 0)
		MtVars_Lua.topDepth += 1

		if (top) { println("----------") }

		try {
			/* 获取元数据（P8/M2：一次收集——静态列缓存重放 + 引用列实时快照） */
			let metadata = getMetadata()

			/*  从元数据浅拷贝（不污染共享源；转发侧复用同一份干净元数据），
			 *  再合并 @Action 传入的实时参数  */
			let obj = JsonObject()
			jsonMergeInto(obj, metadata)
			obj.put("mode", JsonString("call"))
			jsonMergeInto(obj, json.asObject())
			logD({ => "Lua scripts call parameters: ${obj.toString()}" })

			/* 调用Lua解释器 */
			let res = call_lua(L, obj)

			logD({ => "Lua script call result: ${res.toString()}" })
			/* ---- 检查本驱动 call 的返回契约（含显式 ERR 即中断） ---- */
			MatrixVars_Hardware.ensureOk(res, ctx: "call ${luapath}")

			/* ---- controller 转发：元数据 ∪ 自己Lua的返回表 ---- */
			if (let Some(ctrl) <- controller) {
				/* 转发 payload = 同一份干净元数据 ∪ 自己Lua的返回表
				 * （原实现二次 getMetadata()：重复 O(cols·rows) 扫描且引用列被
				 *   read() 两遍；P8/M2 后一次收集两次浅拷贝） */
				let payload = JsonObject()
				jsonMergeInto(payload, metadata)
				jsonMergeInto(payload, res.asObject())
				logD({ => "Forward to controller: ${payload.toString()}" })

				let ctrl_res = ctrl.play(payload)
				logD({ => "Controller result: ${ctrl_res.toString()}" })

				/* ---- 检查 controller 返回值（如 PCA9685 写寄存器失败） ---- */
				MatrixVars_Hardware.ensureOk(ctrl_res, ctx: "controller of ${luapath}")

				if (top) { println(ctrl_res.toString()) }
				return ctrl_res
			}

			if (top) { println(res.toString()) }
			return res
		}
		finally {
			MtVars_Lua.topDepth -= 1
		}
	}

	/*
	 *  无副作用读实现（P4/M1）：Lua 驱动若定义 read(data)（滤波器返回快照）→ 走快照；
	 *  否则回退实时 call（= play({}) 向后兼容，守护/传感器/动作硬件引用语义不变）。
	 *  注意：不做 ensureOk——引用读是数据流而非动作，无样本/无输入属过渡态
	 *  （如滤波器未 pump 前被 build 期引用），不应像显式 play 那样 halt-on-error。
	 */
	private static func readImpl(L: lua_State, getMetadata: () -> JsonObject): JsonValue {
		/* Lua 定义了 read → 快照读；未定义 → 回退实时 call 语义 */
		let mode = if (luaGlobalType(L, "read") != LUA_TNIL) { "read" } else { "call" }
		let metadata = getMetadata()
		metadata.put("mode", JsonString(mode))
		return call_lua(L, metadata)
	}

	/* 硬件构造方法实现：提供元数据（json_obj）对该硬件进行初始化 */
	private static func riseImpl(L: lua_State, luapath: String, getMetadata: () -> JsonObject): Unit {
		/* 在这里构建Lua状态机 */
		if (build_lua(L, luapath) == false) {
			throw Exception("Failed to build Lua state from script: '${luapath}'. Please check if the file exists and is valid Lua code.")
		}

		/* 获取元数据并注入 build 指令 */
		let metadata = getMetadata()
		metadata.put("mode", JsonString("build"))
		logD({ => "Lua scripts build parameters: ${metadata.toString()}" })

		let res = call_lua(L, metadata)

		logD({ => "Lua script build result: ${res.toString()}" })

		/* ---- 检查 build 返回契约：失败即抛（main 的 finally 会清理已建硬件） ---- */
		MatrixVars_Hardware.ensureOk(res, ctx: "build ${luapath}")
	}

	/* 硬件解构方法实现：传入元数据，使用 Lua 状态机对设备进行关闭（或者重置） */
	private static func freeImpl(L: lua_State, luapath: String, getMetadata: () -> JsonObject): Unit {
		/* 防御（M2）：build 失败的变量（脚本未加载）全局 destroy 为 nil——
		 * 调 call_lua 只会得到 "attempt to call a nil value" 的误导性噪音
		 * （0.3.0 后 pcall 失败已显式返回 ERR 契约，噪音随之升级为 deactivate warning）。
		 * 此类状态机无 destroy 可调：跳过调用、释放状态机后正常返回，不抛 ERR，
		 * 与 Daemon/其他硬件变量"未构建即不解析"的语义对齐。 */
		if (luaGlobalType(L, "destroy") == LUA_TNIL) {
			logD({ => "Lua '${luapath}' has no global destroy (not built); skipping destroy call, releasing state" })
			destroy_lua(L)
			return
		}

		/* 获取元数据并注入 destroy 指令 */
		let metadata = getMetadata()
		metadata.put("mode", JsonString("destroy"))
		logD({ => "Lua scripts destroy parameters: ${metadata.toString()}" })

		let res = call_lua(L, metadata)

		logD({ => "Lua script destroy result: ${res.toString()}" })
		/* ---- 先释放 Lua 状态机，再检查返回契约——避免检查抛异常时泄漏 ---- */
		destroy_lua(L)

		/* ---- 检查 destroy 返回契约：ERR 抛出让 deactivate 的 try-catch 记录 ---- */
		MatrixVars_Hardware.ensureOk(res, ctx: "destroy ${luapath}")
	}


	/*  构造Lua状态机  申请资源
	 *
	 *  NOTE(20260618-qing): 构建完毕会运行一次 */
	private static func build_lua(L: lua_State, luapath: String): Bool {
		unsafe {
			/*  加载Lua标准库（os/io等，HAL.lua 依赖；不再注册硬件cfunc）  */
			Lua_loadlib(L)
			sandbox_lua(L)	/* 中和 os.execute/io.popen 等宿主入口（issue #9 M1） */

			/* -------- 设置Lua状态机（malloc 失败由 withCString 抛 IllegalMemoryException）-------- */
			let status = withCString(luapath) { fc: CString =>
				unsafe { Lua_loadfilex(L, fc, CPointer<C_Char>()) }
			}

			if (status == LUA_OK) {
				let pcStatus = Lua_pcall(L, 0, LUA_MULTRET, 0)
				logD({ => "lua build status: ${pcStatus}" })
				if (pcStatus == LUA_OK) { return true  }
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

	/* 将 JsonValue 递归压入 Lua 栈。数组/对象转 Lua 表（H-03）。
	 * 返回后栈顶即该值；不接受的类型（异常安全）压 nil 并留日志。 */
	private static func push_lua_value(L: lua_State, val: JsonValue): Unit {
		if (val is JsonString) {
			let v = val.asString().getValue()
			withCString(v) { sv: CString => unsafe { Lua_pushstring(L, sv) } }
		}
		else if (val is JsonInt) {
			unsafe { Lua_pushinteger(L, Int64(val.asInt().getValue())) }
		}
		else if (val is JsonFloat) {
			unsafe { Lua_pushnumber(L, val.asFloat().getValue()) }
		}
		else if (val is JsonBool) {
			let b = if (val.asBool().getValue()) { 1 } else { 0 }
			unsafe { Lua_pushboolean(L, Int32(b)) }
		}
		else if (val is JsonNull) {
			unsafe { Lua_pushnil(L) }
		}
		else if (val is JsonArray) {
			let arr = val.asArray()
			unsafe { Lua_createtable(L, Int32(arr.size()), 0) }
			for (i in 0..arr.size()) {
				push_lua_value(L, arr.get(i).getOrThrow())
				unsafe { lua_rawseti(L, -2, Int64(i + 1)) }
			}
		}
		else if (val is JsonObject) {
			let obj = val.asObject()
			unsafe { Lua_createtable(L, 0, 0) }
			let fs: HashMap<String, JsonValue> = obj.getFields()
			for (k in fs.keys()) {
				push_lua_value(L, fs.get(k).getOrThrow())
				withCString(k) { sk: CString => unsafe { Lua_setfield(L, -2, sk) } }
			}
		}
		else {
			logD({ => "push_lua_value: unsupported JsonValue type, pushed nil" })
			unsafe { Lua_pushnil(L) }
		}
	}

	/* 读取 Lua 栈上 index 处的值并转换为 JsonValue（递归）。table 转 JsonArray/JsonObject；
	 * 不接受的类型（function/userdata 等）回 JsonNull（H-03）。调用前后栈深度不变。 */
	private static func lua_value_to_json(L: lua_State, idx: C_Int): JsonValue {
		let t = unsafe { Lua_type(L, idx) }
		if (t == LUA_TNUMBER) {
			let d = unsafe { Lua_tonumber(L, idx) }
			let i = unsafe { Lua_tointeger(L, idx) }
			return if (Float64(i) == d) { JsonInt(i) } else { JsonFloat(d) }
		}
		else if (t == LUA_TBOOLEAN) {
			let b = unsafe { Lua_toboolean(L, idx) }
			return JsonBool(b != 0)
		}
		else if (t == LUA_TNIL) {
			return JsonNull()
		}
		else if (t == LUA_TSTRING) {
			let s = unsafe { Lua_tostring(L, idx) }
			return JsonString(s.toString())
		}
		else if (t == LUA_TTABLE) {
			let arrKeys = ArrayList<Int64>()
			let arrVals = HashMap<Int64, JsonValue>()
			let obj = JsonObject()
			unsafe {
				lua_pushvalue(L, idx)	/* 表副本到栈顶 */
				Lua_pushnil(L)
				while (Lua_next(L, -2) != 0) {
					let keyType = Lua_type(L, -2)
					if (keyType == LUA_TNUMBER) {
						let k = Lua_tointeger(L, -2)
						let vj = lua_value_to_json(L, -1)
						arrVals.add(k, vj)
						arrKeys.add(k)
					}
					else if (keyType == LUA_TSTRING) {
						let ks = Lua_tostring(L, -2)
						let vj = lua_value_to_json(L, -1)
						obj.put(ks.toString(), vj)
					}
					Lua_pop(L, 1)	/* 弹出值，保留键供下一次 Lua_next */
				}
				Lua_pop(L, 1)	/* 弹出表副本 */
			}
			if (arrKeys.size > 0) {
				/* toArray 为拷贝，必须排序拷贝后按其迭代——原实现对拷贝排序等于没排 */
				let sortedKeys = arrKeys.toArray()
				sort(sortedKeys)
				if (obj.getFields().size > 0) {
					/* 混合键表：数组表达不了字符串键——整体转对象（数字键转字符串键），不丢字段 */
					for (k in sortedKeys) { obj.put("${k}", arrVals.get(k).getOrThrow()) }
					return obj
				}
				let arr = JsonArray()
				for (k in sortedKeys) { arr.add(arrVals.get(k).getOrThrow()) }
				return arr
			}
			if (obj.getFields().size > 0) { return obj }
			return JsonArray()	/* 空表 → 空数组 */
		}
		else {
			logD({ => "lua_value_to_json: unsupported Lua type ${t}, returned null" })
			return JsonNull()
		}
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
			withCString(mode) { cstr: CString => unsafe { Lua_getglobal(L, cstr) } }

			/* ----在Lua状态机里 创建Lua表 ---- */
			Lua_createtable(L, 0, 0)


			/* ---- 向Lua表中推入数据（H-03：数组/对象/字符串统一走递归转换） ---- */
			let fields: HashMap<String, JsonValue> = obj.getFields()
			for (k in fields.keys()) {
				let val = fields.get(k).getOrThrow()
				push_lua_value(L, val)
				withCString(k) { sk: CString => unsafe { Lua_setfield(L, -2, sk) } }
			}

			let status = Lua_pcall(L, 1, LUA_MULTRET, 0)
			logD({ => "lua status: ${status}" })
			if (status == LUA_OK) {
				if (Lua_type(L, -1) == LUA_TTABLE) {
					/* ---- 栈顶是表  压入 nil 作为遍历的起始键 ---- */
					Lua_pushnil(L)
					while(Lua_next(L, -2) != 0) {
						/* ---- 此时栈：[表, 键, 值] ----
						 * H5 加固（issue #5 清单）：键只接受 string——Lua 手册警告遍历期间
						 * 对【键】调 lua_tolstring 会原地改写键值，数字键将扰乱后续 lua_next；
						 * 值经 lua_value_to_json 递归转换（H-03：table → JsonArray/JsonObject，
						 * 其余不可转换类型回 JsonNull 而非跳过）。 */
						let keyType = Lua_type(L, -2)
						if (keyType != LUA_TSTRING) {
							logD({ => "Lua return field skipped: key type ${keyType}" })
							Lua_pop(L, 1)	/* 弹出值，保留键供下一次 Lua_next */
							continue
						}
						let key = Lua_tostring(L, -2)
						let val = lua_value_to_json(L, -1)
						logD({ => "${key}: ${val.toString()}" })
						ret.put(key.toString(), val)
						Lua_pop(L, 1)
					}
				}
			}

			else {
				let errStr = luaErrorString(L)
				println("Lua 错误详情: ${errStr}")
				/* pcall 失败若返回空表（无 result 字段）会被 ensureOk 视为成功，
				 * 驱动运行时错误将静默放行——必须显式带 ERR 契约 */
				ret.put("result", JsonString("ERR"))
				ret.put("message", JsonString(errStr))
			}

			/* -------- 恢复Lua状态机 -------- */
			Lua_settop(L, top)
		}
		return ret
	}
}
