/*
 *  硬件变量基类（自 RobotStruct.cj 迁出）
 *  接收3个lambda表达式，在回调函数中定义行为
 *  通过JsonValue这种通用的数据结构进行传值
 *
 *  说明：析构器（终结器）的调用时间不确定，故手动构造 RAII 机制（build/destroy）。
 *  未来规划（详见 README 待实现功能）：
 *  TODO(20260519-qing): 考虑将@Action矩阵对象置为硬件变量的一种
 *  TODO*(20260529-qing): 增加微调器机制，通过不同的微调器对@Action进行微调
 */

package bot4cj.HV
import std.convert.*
import std.env.*
import stdx.encoding.json.*
import mt2.*

public open class MatrixVars_Hardware {

	/*
	 *  ---------------- 调试开关 ----------------
	 *  环境变量 BOT4CJ_DEBUG=1 开启 call/build/destroy 的参数表、结果表、
	 *  逐键值、lua status 等详细日志（高频刷屏）；默认关闭。
	 *  错误信息、生命周期摘要（spawn/join/publishes）与构建期单次输出不受影响。
	 *  -------------------------------------------
	 */
	public static let debugEnabled: Bool = initDebugEnabled()

	/*
	 *  读取一次 BOT4CJ_DEBUG 并按 "1" 判定。
	 *  <staticmethod>
	 */
	public static func initDebugEnabled(): Bool {
		if (let Some(v) <- getVariable("BOT4CJ_DEBUG")) {
			return v == "1"
		}
		return false
	}

	/*
	 *  惰性调试日志：接收 () -> String，仅 debugEnabled 时才求值消息体。
	 *  背景：0.3.3 曾因热路径 logD("${obj.toString()}") 无条件求值产生大量
	 *  临时字符串（GC 压力崩溃），改条件求值后仍有 10 处调用点漏改——
	 *  惰性签名从类型上根除该问题（非 debug 模式下插值代码根本不执行）。
	 */
	public static func logD(msg: () -> String): Unit {
		if (debugEnabled) { println(msg()) }
	}

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
	 *  TODO(20260612-qing): 使用某种方式记录变量是否经过了初始化
	 */
	public func play(input: JsonValue): JsonValue {  return things(input)  }

	/*
	 *  -------------------------------- *
	 *  无副作用读（P4/M1）：引用机制（_getMetadata 的"引用列即变量名"）一律走 read()。
	 *
	 *  缺省实现 = play({})（实时读，向后兼容）：守护读共享槽快照、传感器读实时值，
	 *  均无状态副作用。有状态的硬件（Lua 驱动如 Ema/Kalman 滤波）在 Lua 侧定义
	 *  read(data) 返回最近一次 call 的输出快照、不推进状态——见 MtVars_Lua.read()
	 *  （Lua 未定义 read 时其 fallback 也回到本实时语义）。
	 */
	public open func read(): JsonValue {  return this.play(JsonObject())  }

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

	/*
	 * ----------------------------------
	 * 硬件调用结果契约检查（halt-on-error）
	 *
	 * 统一约定：Lua 驱动返回 { result = "OK" | "ERR", message = "..." }。
	 * 不含 result 字段视为成功（兼容转发类驱动如 Relay/Servo；总线三件套
	 * I2C/SPI/UART 的 call 现均带 result）；含显式 "ERR"
	 * 时抛出异常，由调用方决定中断动作序列还是捕获继续。
	 */
	public static func ensureOk(res: JsonValue, ctx!: String = ""): JsonValue {
		if (!(res is JsonObject)) { return res }
		let obj = res.asObject()
		if (let Some(rs) <- obj.get("result")) {
			if (rs is JsonString) {
				if (rs.asString().getValue().trimAscii() == "ERR") {
					var msg = "Hardware call failed (${ctx})"
					if (let Some(m) <- obj.get("message")) {
						if (m is JsonString) {
							msg = "${msg}: ${m.asString().getValue()}"
						}
					}
					throw Exception(msg)
				}
			}
		}
		return res
	}


	/* ---------------------------------- */
}

/*
 * ----------------------------------
 * JsonObject 浅合并：把 src 的所有字段写入 dst（同名覆盖）。
 * 此前该 4 行循环在 MtVars_Lua.callImpl（元数据拷贝/参数合并/转发 payload）
 * 与 MetaProvider.collect（引用列快照合并）中重复 5 处。
 */
public func jsonMergeInto(dst: JsonObject, src: JsonObject): Unit {
	let fields = src.getFields()
	for (k in fields.keys()) {
		dst.put(k, fields.get(k).getOrThrow())
	}
}
