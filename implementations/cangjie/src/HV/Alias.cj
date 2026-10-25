/*  别名变量（硬件类型，自 RobotStruct.cj 迁出）
 *  这种变量用于给某个参数取一个更简单的别名  它的事件返回（JsonString）将作为新的矩阵项目值
 */

package bot4cj.HV
import std.collection.*
import stdx.encoding.json.*
import mt2.*

public class MtVars_Alias <: MatrixVars_Hardware {
	public init(things!: (JsonValue) -> JsonValue,
			rise!: Option<() -> Unit> = None,
			free!: Option<() -> Unit> = None  )
	{  super(things: things, rise: rise, free: free)  }

	public static func Factory(defs: MatrixObject, i: Int64,
			_: HashMap<String, MatrixVars_Hardware>): MtVars_Alias
	{
		let idxName = defs.indexOfCol(0, "name")
		let idxAlias= defs.indexOfCol(0, "alias")

		let name = defs[i, idxName]
		let alias= getMt(defs, i, idxAlias)

		println("Create an Alias vars: ${name}, which means ${alias}")
		let aliasVar = MtVars_Alias(things: {_: JsonValue =>
			let str = JsonString(alias)	/*  直接返回JsonString（alias）*/
			return str
		})

		return aliasVar
	}
}
