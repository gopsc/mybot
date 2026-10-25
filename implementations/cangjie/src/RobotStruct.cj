/*
 *  机器人构成模块：确定机器人结构，从解析出的矩阵对象构建硬件变量
 *  TODO(20260527-qing): 使脚本中的数值亦可从运行时确定
 */

package bot4cj
import std.io.*
import std.collection.*
import std.env.*
import stdx.encoding.json.*
import mt2.*
import SQL4cj.*
import bot4cj.HV.*


/* 机器人结构类
 *
 * 机器人结构是动态的：接受输入流，随后逐个解析存入链表。
 *
 * 未来规划（详见 README 待实现功能）：
 * TODO(20260518-qing): 使用神经网络RNN直接根据动作+传感器脚本生成下一步动作
 * TODO(20260527-qing): 增加硬件模块行为脚本
 * TODO*(20260527-qing): 为@Action表演矩阵对象增加位置指示器，以增量行动
 */
class RobotStruct {

	/* -------- 结构脚本解析出的矩阵对象（按脚本声明序） -------- */
	private let matrices = LinkedList<MatrixObject>()
	/* -------- 守护 holder 注册表：deactivate 先统一置 stop 再 join（防 worker 饿死死锁）-------- */
	private let daemonHolders = ArrayList<DaemonHolder>()
	/* -------- 硬件变量注册表：名字 → 硬件变量 -------- */
	private let hardwareVars = HashMap<String, MatrixVars_Hardware>()
	/* 硬件变量声明序列：active/deactivate 按声明序 build/destroy
	 * （HashMap 遍历序未定义，而 I2C→PCA9685 等 fd 依赖要求声明序） */
	private let hwSeq = ArrayList<MatrixVars_Hardware>() 

	/* -------- 安全添加硬件变量（检查重复键；source 用于报错时指明声明来源） -------- */
	private func addHardwareVar(name: String, hw: MatrixVars_Hardware, source!: String = "") {
		if (let Some(_) <- hardwareVars.get(name)) {
			throw IllegalArgumentException("Duplicate hardware variable name: '${name}'${source}")
		}
		hardwareVars[name] = hw
		hwSeq.add(hw)
	}

	/* -------- 重名前置判重（资源泄漏防线）--------
	 * MtVars_Lua.Factory（LuaJIT 状态机）与 MtVars_Daemon.Factory（共享槽 + mutex）
	 * 都在实参求值时先申请 OS 资源，addHardwareVar 后置查重抛错后资源无人持有、
	 * 无法回收——当前错误路径进程退出由 OS 兜底，但长驻进程（未来 TCP 模式）
	 * 每次重试都会累积泄漏。先确认名字可用再调 Factory；
	 * addHardwareVar 保留为权威兜底（报错文案一致）。 */
	private func precheckDuplicate(name: String, mtName: String): Unit {
		if (let Some(_) <- hardwareVars.get(name)) {
			throw IllegalArgumentException("Duplicate hardware variable name: '${name}' (in table '${mtName}')")
		}
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
			let aliasVar = MtVars_Alias.Factory(matrix, i, hardwareVars)
			if (let Some(set) <- session) {
				if (set.contains(name)) {
					throw IllegalArgumentException("Duplicate alias name '${name}' within the action script")
				}
				set.add(name)
				if (let Some(_) <- hardwareVars.get(name)) {
					println("Alias '${name}' defined in action script overrides the structure definition")
				}
				hardwareVars[name] = aliasVar
			}
			else {
				addHardwareVar(name, aliasVar, source: " (in @Alias matrix)")
			}
		}
	}

	/*
	 *  使用矩阵脚本驱动机器人（两阶段构造·阶段一：纯解析）
	 *
	 *  只做 SQL 解析，不申请任何 OS 资源——解析期抛错零清理负担；
	 *  资源创建在 active()（阶段二），与其配对的 deactivate() 保证回收。
	 */
	public init(input: InputStream) {
		readSQL(input, matrices)
	}

	/* -------- 激活所有硬件变量（两阶段构造·阶段二：创建 + build）--------
	 * createHardVars 与 build 均可能抛错（重名 / controller 未定义 /
	 * Lua 脚本加载失败等）；调用方（main）以 finally deactivate 配对——
	 * 异常路径下已创建的硬件变量按 hwSeq 声明序倒序回收，长驻进程
	 * （未来 TCP 模式）可安全清理重试。
	 * 仅可调用一次：重复调用会对同名硬件再次判重抛错。 */
	public func active(): Unit {
		createHardVars()
		for (item in hwSeq) {
			item.build()
		}
	}

	/*
	 *  消除所有硬件变量
	 *
	 *  清除必须以倒序进行（I2C→PCA9685 等 fd 依赖要求先销毁依赖方）。
	 */
	public func deactivate(): Unit {
		/* P1 防死锁：先给【所有】守护置 stop，再统一 join。
		 * 否则逐个 stop+get 时，若先 join 一个被 worker 池饿死的守护，其余守护
		 * （stop 未置位）仍独占 worker → 饿死者永不运行 → get() 永久阻塞。
		 * 全部置 stop 后：运行中的守护退出释放 worker，饿死者随后拿到 worker 即见 stop 退出。
		 * P2：stop 经槽内 mutex 临界区写入（acquire/release），消除数据竞争 */
		for (h in daemonHolders) {
			daemon_request_stop(h.slot)
		}
		let items = hwSeq.toArray()
		for (i in items.size-1..=0:-1) {
			/* 单个 destroy 失败不阻塞后续清理（记录并继续） */
			try { items[i].destroy() }
			catch (e: Exception) { println("Deactive warning: ${e}") }
		}
	}

	/* -------- 执行@Action矩阵中的内容 -------- */
	public func run(input: InputStream): Unit {
		let actionMatrices = LinkedList<MatrixObject>()
		readMatrix(input, actionMatrices)

		/* ---- 注册动作脚本中内联的 @Alias（同名时覆盖结构脚本的定义） ---- */
		let session = HashSet<String>()
		for (matrix in actionMatrices) {
			if (matrix.getName().trimAscii() == "Alias") {
				registerAliasMatrix(matrix, Some(session))
			}
		}

		runAction(actionMatrices)
	}

	/*
	 *  储存整个矩阵变量表
	 *
	 *  调用方使用完毕后应关闭输出流。
	 *
	 *  说明：本方法是预留的公开 API，为 NN 模块接入矩阵脚本存储而保留
	 *  （调用点见 main.cj 中随 NN 段一并注释的 robot.save(outf)）。
	 *  当前编译产物中无调用者，会产生 unused function 警告——属预期，
	 *  待 NN 功能恢复后即被启用，请勿按死代码删除。
	 */
	public func save(out: OutputStream): Unit {
		let ms = MatrixSaver(out)
		ms.save(matrices)
	}

	/*
	 *  阅读矩阵脚本
	 *  TODO(20260504-qing): 使用矩阵脚本存储神经网络模型（未来 NN 接入时实现）
	 */
	static private func readMatrix(file: InputStream, out: LinkedList<MatrixObject>){
		let sr = StringReader<InputStream>(file)
		let parser =  MatrixParser(sr)
		while (true) {
			if (let Some(O) <- parser.parse()) {
				out.addLast(O)  }
			else { break }
		}
	}

	static private func readSQL(input: InputStream, out: LinkedList<MatrixObject>) {
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
					out.addLast(mt)

				case INSERT_TABLE(ev) =>

					/* ---- 目标表须先经 CREATE TABLE 定义：表名拼错时原实现静默
					 * ---- 跳过整条 INSERT，硬件实例无声消失，错误延迟到动作期
					 * ---- 以误导性信息（'xx' not defined）暴露——现解析期显式报错。
					 * ---- forEach 改 for 循环：lambda 不得捕获可变变量（matched） ---- */
					var matchedTable = false
					for (item in out) {

						if (ev.targetTabName == item.getName()) {
							matchedTable = true

							var rowNo = 0
							for (row in ev.tableRows) {
								rowNo += 1
								/* ---- INSERT 值列与表头逐列匹配；缺列/重复列/未知列
								 * ---- 会使矩阵单元静默错位（动作打到错误舵机），显式报错 ---- */
								for (i in 0..item.col) {
									var matched = 0
									for (col in row) {
										if (col.columnName == item[0, i]) {
											matched += 1
											if (matched > 1) {
												throw IllegalArgumentException("INSERT INTO ${ev.targetTabName} row ${rowNo}: duplicate column '${col.columnName}'")
											}
											for (ch in col.value) {
												item.addRune(Rune(ch))
											}
											item.submitItem()
										}
									}
									if (matched == 0) {
										throw IllegalArgumentException("INSERT INTO ${ev.targetTabName} row ${rowNo}: column '${item[0, i]}' is missing")
									}
								}
								for (col in row) {
									var known = false
									for (i in 0..item.col) {
										if (col.columnName == item[0, i]) { known = true; break }
									}
									if (!known) {
										throw IllegalArgumentException("INSERT INTO ${ev.targetTabName} row ${rowNo}: unknown column '${col.columnName}'")
									}
								}
								item.submitLine(0)
							}
						}
					}
					if (!matchedTable) {
						throw IllegalArgumentException(
							"INSERT INTO '${ev.targetTabName}': table is not defined. CREATE TABLE must appear before INSERT (check for typos in the table name).")
					}

				case _ => throw Exception("Unsupported sql command")
			}
		}
	}

/*
	 *  创建硬件变量字典
	 *
	 *  按矩阵类型分派到独立创建方法（各硬件类型工厂逻辑自洽，便于单独测试）：
	 *    Alias   → 别名硬件（结构脚本侧注册，重名直接抛错）
	 *    Action  → 跳过（动作由 run() 阶段读取）
	 *    Daemon  → 守护线程硬件（spawn 绿色线程 + 共享内存槽）
	 *    其余    → 通用 Lua 脚本硬件（走 MetaProvider 元数据 + 可选 controller 转发）
	 */
	private func createHardVars() {
		for (matrix in matrices) {
			let mtName = matrix.getName()
			if (mtName == "Alias") {
				registerAliasMatrix(matrix, None)
			}
			else if (mtName == "Action") {
				/* 动作矩阵不在此阶段创建硬件 */
				;
			}
			else if (mtName == "Daemon") {
				createDaemonVars(matrix, mtName)
			}
			else if (matrix.size > 0) {
				createLuaVars(matrix, mtName)
			}
		}
	}

	/* ---- Daemon 守护线程硬件：矩阵每行一个守护变量 ---- */
	private func createDaemonVars(matrix: MatrixObject, mtName: String): Unit {
		let idxName = matrix.indexOfCol(0, "name")
		for (i in 1..matrix.size) {
			let name = matrix[i, idxName]
			precheckDuplicate(name, mtName)
			addHardwareVar(name, MtVars_Daemon.Factory(matrix, i, hardwareVars, daemonHolders), source: " (in table '${mtName}')")
		}
	}

	/* ---- 通用 Lua 脚本硬件：矩阵每行一个硬件变量 ----
	 *  元数据闭包由 MetaProvider 提供静态列缓存 + 引用列实时快照（P8/M2）；
	 *  跳过 controller 列，避免误当作引用 play。 */
	private func createLuaVars(matrix: MatrixObject, mtName: String): Unit {
		let idxName = matrix.indexOfCol(0, "name")

		/* 手动扫描标题行，寻找可选的 controller 列 */
		var idxCtrl: Int64 = -1
		for (j in 0..matrix.col) {
			if (matrix[0, j] == "controller") { idxCtrl = j; break }
		}

		/* 从环境变量 BOT4CJ_MODULE_PATH 获取模块路径（std.env），支持 ':' 分隔多路径，默认为 ./modules */
		let modulePath = getVariable("BOT4CJ_MODULE_PATH") ?? "./modules"
		let scriptPath = firstExistingModule(modulePath, "${mtName}.lua")

		for (i in 1..matrix.size) {
			let name = matrix[i, idxName]
			precheckDuplicate(name, mtName)

			/* 解析该行的 controller 引用（支持 - 占位符继承） */
			var ctrlOpt: Option<MatrixVars_Hardware> = None
			if (idxCtrl >= 0) {
				let ctrlName = MatrixVars_Hardware.getMt(matrix, i, idxCtrl)
				if (ctrlName != "-") {
					if (let Some(hv) <- hardwareVars.get(ctrlName)) {
						ctrlOpt = Some(hv)
					} else {
						throw IllegalArgumentException(
							"Hardware variable '${name}' declares controller '${ctrlName}' in table '${mtName}', but it is not defined yet. The controller must be defined before the matrix that references it.")
					}
				}
			}

			let skipCol = idxCtrl	/* lambda 不得捕获可变变量 */
			let metaProv = MetaProvider(matrix, i, skipCol, hardwareVars)
			addHardwareVar(name, MtVars_Lua.Factory(scriptPath, {=>
					metaProv.collect()
			}, controller: ctrlOpt), source: " (in table '${mtName}')")
		}
	}


	/* -------- 在矩阵对象的容器中寻找目标 -------- */
	private static func findMt(ll: LinkedList<MatrixObject>, name: String): Option<MatrixObject>
	{
		for (item in ll) {
			var target  = item.getName()
			target = target.trimAscii()
			if (name == target) {
				return item  }
		}

		return None
	}

	/* -------- 逐行播放 @Action 矩阵 -------- */
	private func runAction(actionMatrices: LinkedList<MatrixObject>) {
		let actionDefsOpt = findMt(actionMatrices, "Action")
		if (actionDefsOpt.isNone()) {
			throw IllegalArgumentException("No @Action matrix found in script. Please define action matrix in your .mt file.")
		}
		let actionDefs = actionDefsOpt.getOrThrow()	/* MatrixObject */

		/* 按标题行的列顺序收集设备名，保证执行顺序与脚本列序一致
		 * （例如把 Timer(Speaker) 列写在最后，它就会最后执行，见 issue #12） */
		let order = ArrayList<String>()
		for (j in 0..actionDefs.col) {
			let (name_dev, _) = parseActionColumn(actionDefs[0, j])
			if (!order.contains(name_dev)) {
				order.add(name_dev)  }
		}

		for (i in 1..actionDefs.size) {
			let set = JsonObject()		/* 每个硬件变量的参数集合 */
			for (j in 0..actionDefs.col) {
				parseActionCell(set, actionDefs, i, j)
			}

			/* -------- 执行一行 -------- */
			for (name_dev in order) {
				let hvOpt = hardwareVars.get(name_dev)
				if (hvOpt.isNone()) {
					throw IllegalArgumentException("Hardware variable '${name_dev}' is used in @Action (row ${i}) but not defined in hardware declaration section.")
				}
				let hv = hvOpt.getOrThrow()
				let paramsOpt = set.get(name_dev)
				if (paramsOpt.isNone()) {
					throw IllegalArgumentException("Parameter for hardware variable '${name_dev}' is missing in action row ${i}.")
				}
				let params: JsonValue = paramsOpt.getOrThrow()
				let res: JsonValue = hv.play(params)

				/* ---- halt-on-error：硬件 call 返回显式 ERR 即中断剩余动作 ---- */
				MatrixVars_Hardware.ensureOk(res, ctx: "play ${name_dev} (row ${i})")
			}


		}
	}

	/* -------- 解析@Action列头 "<device>.<param>"（唯一校验点） -------- */
	private static func parseActionColumn(name_HV: String): (String, String) {
		let arr = name_HV.split(".")
		if (arr.size != 2) {
			throw IllegalArgumentException("Action column '${name_HV}' is not valid (expect <device>.<param>)")
		}
		return (arr[0], arr[1])
	}

	/* -------- 解析@Action矩阵的一个单元格，参数归入所属设备的参数集合 -------- *
	 * 列名格式 <device>.<param> 由 parseActionColumn 统一校验拆分。 */
	private func parseActionCell(set: JsonObject, actionDefs: MatrixObject,
			i: Int64, j: Int64) {
		let (name_dev, name_param_orig) = parseActionColumn(actionDefs[0, j])
		var name_param = name_param_orig

		var val_fp64 = MatrixVars_Hardware.parseMt<Float64>(actionDefs, i, j)

		/* 参数别名转换：仅当参数名恰好是显式声明的 Alias 变量时才把 name_param
		 * 替换为其目标名；普通硬件变量（守护/传感器/执行器）与参数重名时
		 * 不误触发——保留字面参数名（Low：参数名误命中）。
		 * 引用的 Alias 同样走 read() 快照（P4/M1）。 */
		if (let Some(aliasHV) <- hardwareVars.get(name_param)) {
			if (aliasHV is MtVars_Alias) {
				let ret = aliasHV.read()
				let alias = ret.asString().getValue()
				name_param = alias
			}
		}

		var set_params: JsonObject	/* 设置或者取得属于该硬件变量的参数 */
		if (let Some(obj_) <- set.get(name_dev)) {
			set_params = obj_.asObject()  }
		else {
			set_params = JsonObject()
			set.put(name_dev, set_params)  }

		set_params.put(name_param, JsonFloat(val_fp64))	/* 设置一个该硬件变量的参数 */
	}

}


/* P8/M2：元数据静态列缓存（剔除每 call 两遍 O(cols·rows) 扫描）
 *
 * 原 _getMetadata 每次调用都逐列 getMt（"-" 继承链上溯 O(rows)），
 * 且 controller 转发路径把整行重复收集、引用列被 read() 两遍。
 * 矩阵对象运行期只读（无 restart/rebuild/reload 路径），静态层安全缓存：
 *   - 字面列与 "-" 继承结果   → 首采冻结，之后每次浅拷贝重放；
 *   - "-" 整列缺省（M3）      → 首采 continue 跳过（Lua 侧 tonumber(nil) or 缺省）；
 *   - name 列、controller(skipCol) 列 → 跳过；
 *   - 引用列（值以 $ 前缀显式标记，如 $imu0；裸名一律按字面值）
 *     → 运行期每次实时 read() 快照（P4/M1），
 *     不入缓存，count/nvals/values 等动态值始终反映当前状态。
 * 并发：首采在 build 期单线程完成，静态字段此后只读共享；collect() 每次返回
 * 全新 JsonObject，调用方在副本上写 mode/参数，无共享对象污染（守护多线程 play 安全）。
 * 注意：Cangjie 不支持类内嵌套类，故置于文件顶层（仅供 RobotStruct 使用）。
 */
class MetaProvider {
	let matrix: MatrixObject
	let row: Int64
	let skipCol: Int64
	let hardwareVars: HashMap<String, MatrixVars_Hardware>
	var cols: Option<ArrayList<String>> = None
	var vals: Option<ArrayList<String>> = None
	var refs: Option<ArrayList<String>> = None

	init(matrix: MatrixObject, row: Int64, skipCol: Int64,
			hardwareVars: HashMap<String, MatrixVars_Hardware>) {
		this.matrix = matrix
		this.row = row
		this.skipCol = skipCol
		this.hardwareVars = hardwareVars
	}

	func collect(): JsonObject {
		seed()
		let obj = JsonObject()
		let colsArr = cols.getOrThrow()
		let valsArr = vals.getOrThrow()
		for (k in 0..colsArr.size) {
			obj.put(colsArr[k], JsonString(valsArr[k]))
		}
		for (name in refs.getOrThrow()) {
			if (let Some(mt) <- hardwareVars.get(name)) {
				jsonMergeInto(obj, mt.read().asObject())
			}
		}
		return obj
	}

	func seed() {
		if (let Some(_) <- this.cols) { return }
		let cArr = ArrayList<String>()
		let vArr = ArrayList<String>()
		let rArr = ArrayList<String>()
		let idxName = matrix.indexOfCol(0, "name")
		for (j in 0..matrix.col) {
			let colName = matrix[0, j]
			var value = MatrixVars_Hardware.getMt(matrix, row, j)
			if (value == "-") { continue }
			if (j == idxName || j == skipCol) { continue }
			/* 引用列须显式 $ 前缀（如 $imu0）；裸名一律按字面值——
			 * 消除「字面值恰与硬件变量名相同被误判为引用」的隐式行为。
			 * $ 指向未定义变量属拼写错误，显式报错（信息给出表/列/行/值） */
			if (value.startsWith("$")) {
				let rs = value.toRuneArray()
				let arr = Array<Rune>(rs.size - 1, { i => rs[i + 1] })
				let refName = String(arr)
				if (let Some(_) <- hardwareVars.get(refName)) {
					rArr.add(refName)
				} else {
					throw IllegalArgumentException(
						"'${value}' (column '${colName}') in table '${matrix.getName()}' row ${row}: references hardware variable '${refName}', but it is not defined.")
				}
			}
			else { cArr.add(colName); vArr.add(value) }
		}
		this.cols = cArr
		this.vals = vArr
		this.refs = rArr
	}
}


