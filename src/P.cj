package bot4cj
import std.io.*
import std.math.*
import std.convert.*
import std.collection.*
import bot4cj.math.*

/*
 * 矩阵编程语言 - 基本对象
 * TODO：增加储存到文件系统的功能
 * TODO：神经网络层转换为矩阵对象
 * *INFO(20260826-qing): MatrixObject中除了矩阵，还有缓冲区和用于提交的成员函数
 * --------------------------------
 */
class MatrixObject {
	private var name: String = ""		/* -------- 名字 -------- */
	private var tmp = ArrayList<Rune>()	/* ---- rune buf 字符缓冲区 ---- */
	private var grp = ArrayList<String>()	/* ---- one line 整行缓冲区 ---- */
	private var values = ArrayList<ArrayList<String>>()	/* ---- 原始矩阵 ---- */

	/* -------- 是否已命名 -------- */
	public func hasName(): Bool { !(name == "") }

	/* --------- 获得名字 --------- */
	public func getName(): String { return name }

	/* ------- 取动作的长度 ------- */
	public mut prop size: Int64 {
		get() { values.size }
		set(_) {}
	}

	/* -------- 取动作的列数 -------- */
	public mut prop col: Int64 {
		get() {

			if (this.size > 0) {
				return values[0].size
			} else {
				return 0
			}

		}

		/* FIXME: 只能取 */
		set(_) {}
	}

	/* ------- 获取矩阵元素，只能取，不能修改 ------- */
	public operator func [](row: Int64, col: Int64): String {
		return values[row][col]
	}

	/* -- 在某一行中寻找某一个字符串的列号 -- */
	public func indexOfCol(row: Int64, key: String): Int64 {
		for (col in 0..values[row].size) {
			if (values[row][col] == key) {
				return col  }
		}

		/* ---- 没找到 ---- */
		throw IllegalArgumentException("The key does not found.")
	}

	/*  -----  储存对象 ----- */
	public func save(output: StringWriter<OutputStream>) {
		output.writeln("@${getName()}")
		for (vec in values) {
			for (item in vec) {
				output.write(item)
				output.write(" ")
			}
			output.writeln(";")
		}
		output.writeln("@")
	}

	/* -------- 添加字符 -------- */
	public func addRune(c: Rune) {  tmp.add(c)  }

	/* -------- 提交名字 -------- */
	public func submitName() {
		if (tmp.size == 0) { return }
		let s = String(tmp)
		tmp.clear()
		name = s
	}

	/* -------- 提交元素 -------- */
	public func submitItem() {
		if (tmp.size == 0) { return }
		let s = String(tmp)
		tmp = ArrayList<Rune>()
		grp.add(s)
	}

	/* -------- 提交行 -------- */
	public func submitLine(count: Int64) {
		if (grp.size == 0) { return }
		if (values.size != 0 && grp.size != values[values.size - 1].size)
			{ throw DoesNotSync(count) }
		values.add(grp)
		grp = ArrayList<String>()
	}
}

/* ---------------- 对Nn1进行扩展 ---------------- */
//extend Nn1 {
//	/* -------- 转换为MatrixObject对象 -------- */
//	public func toMto(): MatrixObject {
//		let mto = MatrixObject()
//		return mto
//	}
//}

/*  -------- 矩阵式解析器 --------
 *  TODO(20260514-qing): 这个类输入流数据，输出MatrixObject对象
 *  它是与其深度绑定的，我倾向于将其与MatrixObject融合
 *  即持有HashMap<String, ArrayList<ArrayList<String>>>
 *
 *  INFO(20260826-qing): MatrixParser解析出有效字符后会添加到
 *  	所持有MatrixObject的缓冲区，并在分隔符处进行提交 */
class MatrixParser {

	/* ---- 静态判断Option<Rune>是否有值 ----
	   - 该方法用于文本文件遍历时判空  */
	private static func hasValue(co: Option<Rune>): Bool {
		match(co) {
			case Some(_) => true
			case None => false
		}
	}

	/* -------- 主初始化器（构造函数） --------
	   - 设置目标输入流  */
	private var input: StringReader<InputStream>
	public init(input: StringReader<InputStream>) {
		this.input = input  }

	/* -------- 切换目标输入流 -------- */
	public func reset(input: StringReader<InputStream>) {
		this.input = input  }

	/* -------- 解析器 - 循环不变式 ----------------------
	 * -------- 初始化： ss是一个动作脚本的输入流 --------
	 * -------- 保持： ss是动作脚本剩余部分的输入流 ------
	 * -------- 终止： 当输入流为空时，循环终止 ----------  */
	private var obj = MatrixObject() 
	public func parse(): Option<MatrixObject> {
		var count = 1i64		/* 行计数器始于1 */
		flag = false			/* 重置结束标志 */
		this.obj = MatrixObject()	/* 创建一个新的对象，一次只解析一个对象 */
		var so = input.read()		/* 获取初始状态 */
		while (!flag && hasValue(so)) {
			try {
				let s = so.getOrThrow()
				count = _next(s, count)	/* 进行解析解析 */
				so  = input.read()	/* 为下一次循环提供条件 */
			}
			catch (exp: BufOverTheLine) { throw exp }
			catch (exp: IllegalArgumentException) { throw IllegalArgumentException("Parse failed at line ${count}") } 
			catch (exp: Exception) { throw UnknowExcept(count) }	/* FIXME: 还是暴露出原来的错误位置来更好？ */
		}

		/* 如果没有新的矩阵式对象（意外终止）则返回空 */
		if (!obj.hasName()) {  return None  }
		return  obj	/* 否则为解析成功正常退出，返回解析到的矩阵式对象 */
	}

	private var flag = false	/* 结束标志 */
	private var nl: Bool = true	/* new line */
	private var cm: Bool = false	/* comment */
	private var nm: Bool = false	/* name-line */
	private func _next(c: Rune, ct: Int64): Int64 {
		var count = ct
		/* ------------ COMMENTS ------------ */
		if (!cm && c == r'#') { cm = true }	/* 注释开始时 */
		else if (cm && c == r'\n') {		/* 注释结束时 */
			nl = true
			cm = false
			count += 1
		}
		else if (cm && c != r'\n') { ; }	/* 注释进行时 */ 
							/* FIXME: EOF情况 */
		/* ------------ new line ------------ */
		else if (nl && (c == r' ' || c == r'\t' || c == r'\r')) { ; }	/* 新行空字符，维持现状 */
		else if (nl && c == r'\n') {	/* 新行空行 */
			count += 1
		}
		else if (nl && c == r'@' && !obj.hasName()) {
			nl = false
			nm = true
		}
		else if (nl && c == r'@' && obj.hasName()) {
			flag =true
			nl = false
			nm = true
		}
		else if (nl && c != r'@') {	/* 新行内容 */
			nl = false
			obj.addRune(c)
		}
		/* ------------- not nl ------------- */
		else if (!nl &&  nm && (c == r' ' || c == r'\t' || c == r'\n')) {	/* 添加名字 */
			obj.submitName()
			nl = true
			nm = false
		}
		else if (!nl && !nm && (c == r' ' || c == r'\t' || c == r'\n')) {	/* 添加命名项 */
			obj.submitItem()
			if (c ==  r'\n') { count += 1 }
		}
		else if (!nl && c == r';') {	/* 普通行结束 */
			obj.submitItem()
			obj.submitLine(count)
			nl = true
		} 
		else if (!nl) {	// 非空格、非制表符、非分号
			obj.addRune(c)
		}

		/* -------- 返回行号 -------- */
		return count
	}

}

/* -------- 矩阵式储存器 -------- 
 * - 接收矩阵式的哈希表（HashMap<String, MatrixObject>）
 * - 以及一个输出流（在构造函数）。
 *
 * ========
 * INFO(20260626-qing): 设置好输出流，然后输入MatrixObject
 *	每输入一个就存储进入
 */
class MatrixSaver {
	private let stringWriter: StringWriter<OutputStream>
	public init(output: OutputStream) {
		stringWriter = StringWriter(output)  }
	public func save(C: LinkedList<MatrixObject>) {
		for (item in C) {
			item.save(stringWriter)
			stringWriter.writeln()	/* 对象之间空一行 */
			stringWriter.flush()  }
	}
}


/* --------------------------------------------------------- */
/* --------------------------------------------------------- */
/* TODO(20260516-qing): 继续完善异常种类 */

/* -------- 解析异常 -------- */
open class ParseExcept <: Exception {
	public ParseExcept(msg: String, line: Int64) {
		super('${msg}. we got line: ${line}')  }
}

/* -------- 缓冲区过长 -------- */
class BufOverTheLine <: ParseExcept {
	BufOverTheLine(count: Int64) {
		super('Buffer length over the line', count)  }
}

/* -------- 行没对齐 -------- */
class DoesNotSync <: ParseExcept {
	DoesNotSync(count: Int64) {
		super("Matrix Line Does Not Sync", count)  }
}

/* -------- 未知异常 -------- */
class UnknowExcept <: ParseExcept {
	UnknowExcept(count: Int64) {
		super("I don't understand what happened", count)  }
}


