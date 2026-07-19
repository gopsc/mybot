/* 魔改自github tryC项目。手写简易的解释器，我们
 * 将用它来作为操作界面的shell。
 *
 * 也许我们可以增加一些字符串赋值、拼接的能力
 * 同时未来也需要加入系统调用的能力
 *
 *
 * 20250827(qing): 增加了宽字符支持。
 * 20250827(qing): 修复了Str漏匹配的BUG
 * 20250827(qing): 该脚本在操作不当的情况下可能会发生内存泄漏
 * 20250827(qing): 使用longjmp()代替exit()
 */

#include <stdlib.h>
#include <float.h>
#include <string.h>
#include <wchar.h>
#include <wctype.h>
#include "console.h"
#define POOLSIZE (1 * 128)  /* 任意大小 */
#define SYMTABSIZE (1 * 128) /* ！符号表栈的大小 */
#define MAXNAMESIZE 16        /* 变量/函数名称的长度 */
#define RETURNFLAG DBL_MAX    /* 表明函数中已经出现return语句 */


typedef struct symStruct {	/* 该结构体表示存储在符号表中的一个符号 */
  int type;                   /* 符号的类型：Num, Char, Str, Array, Func */
  wchar_t name[MAXNAMESIZE];  /* 记录符号名称 */
  double value;               /* 记录符号的值，或者字符串或数组的长度 */
  union {
    wchar_t *funcp;           /* 指向一个数组或者一个函数 */
    struct symStruct* list;
  } pointer;
  int levelNum;               /* 表明声明的嵌套层级 */
} symbol;
static symbol symtab[SYMTABSIZE];
static int symPointer = 0;     /* 符号表栈指针 */
static int currentlevel = 0;   /* 当前嵌套层级 */

static wchar_t *src, *old_src; /* 当前正处理的文本 */
static wchar_t *p_src;		/* 用于定位释放点 */
static int top_src = 0;


enum {				/* 解释器状态枚举 （使用int直接接受匿名枚举） */
  debug, run
};
static int compileState = run; /* 当前解释器状态 */

static double return_val = 0;  /* 用于保存函数的返回值 */


enum {		/* 标记和类别（运算符放最后并按优先级排序） */
  Num = 128, Char, Str, Array, Func,
  Else, If, Return, While, Print, Puts, Read,
  Assign, OR, AND, Equal, Sym, FuncSym, ArraySym, Void,
  Nequal, LessEqual, GreatEqual
};
static int token; /* 当前标记类型 */
union tokenValue {
  symbol *ptr;  /* 在返回字符串或符号地址用于赋值时使用 */
  double val;   /* 用于字符或数字时标记值 */
} ;

static union tokenValue token_val;

/*--------------- 函数声明 ---------------*/
static double function();
static double statement();
static int boolOR();	/* 用于辅助IF和WHILE词元 */
static int boolAND();
static int boolexp();
static double expression();
static double factor();
static double term();
static void match(int tk);
static void next();
/////
static void clear(int level);
static void clearThis();	/* 20260707(qing): 增加一个clearThis()函数，用于释放变量 */
static void __exit();
/* -------------------  词法分析  -------------------*/

/* 输入字符串的下一个标记 */
static void next() {
  wchar_t *last_pos;
  while(token = *src) {	/* 逐字扫描 */
    ++src;
    if (token == L'\n') {	/* 记录新行的起点 */
      //if (compileState == debug) 
      //  wprintf(L"%.*ls", (int)(src-old_src), old_src);
      old_src = src;
    }
    else if (token == L'#') {	/* 跳过注释 */
      while(*src != 0 && *src != L'\n') {
        src++;
      }
    }
    /* ---- 检查到标识符 ---- */
    else if ((token >= L'a' && token <= L'z') || (token >= L'A' && token <= L'Z') || (token == L'_') || (token > 0x7F)) {
      last_pos = src -1;	/* 程序标识符 */
      wchar_t nameBuffer[MAXNAMESIZE];
      nameBuffer[0] = token;	/* 扫描标识符 */
      while ((*src >= L'a' && *src <= L'z') || (*src >= L'A' && *src <= L'Z') || (*src >= L'0' && *src <= L'9') || (*src == L'_') || (*src > 0x7f)) {
        nameBuffer[src-last_pos] = *src;
        src++;
      }
      nameBuffer[src-last_pos] = 0;	/* 获取标识符名 */
      int i;
      for (i=symPointer-1; i>=0; --i) {	/* 在符号表中搜索符号 */
        if (wcscmp(nameBuffer, symtab[i].name) == 0) {  /* 如果找到符号：根据符号类型返回标记 */
        
          if (symtab[i].type == Num || symtab[i].type == Char) {
            token_val.ptr = &symtab[i];
            token = Sym;
          }
          else if (symtab[i].type == Str) { /* 20250827(qing): 新增此分支，修复BUG */
              token = Str;
              token_val.ptr = (symbol *)symtab[i].pointer.funcp;
          }
          else if (symtab[i].type == FuncSym) {
            token_val.ptr = &symtab[i];
            token = symtab[i].type;
          }
          else if (symtab[i].type == ArraySym) {
            token_val.ptr = &symtab[i];
            token = symtab[i].type;
          }
          else {
            if (symtab[i].type == Void) {
              token = Sym;
              token_val.ptr = &symtab[i];
            }
            else {	// ？？？
              token = symtab[i].type;
              token_val.ptr = NULL; /* 以防万一，为当前记号存储器赋个值！
				     * 因为Array记号可能到这里来，它会在检查失败后检查释放 */
            }
          }
          
          return;
        }
      }
      wcscpy(symtab[symPointer].name, nameBuffer);    /* 如果标记未被发现，创建一个新的 */
      symtab[symPointer].levelNum = currentlevel;
      symtab[symPointer].type = Void;
      token_val.ptr = &symtab[symPointer];
      symPointer++;
      token = Sym;
      return;
    }
    else if (token >= L'0' && token <= L'9') {
      token_val.val = (double)token - L'0';
      while (*src >= L'0' && *src <= L'9') {
        token_val.val = token_val.val * 10.0 + *src++ - L'0';
      }
      if (*src == L'.') {
        src++;
        int countDig = 1;
        while (*src >= L'0' && *src <= L'9') {
          token_val.val = token_val.val + ((double)(*src++) - L'0') / (10.0 * countDig++);
        }
      }
      token = Num;
      return;
    }

    /* 字符 */
    else if (token == L'\'') {  
      token_val.val = *src++;
      token = Char;
      src++;
      return;
    }

    /* 字符串 */
    else if (token == L'"') { 
      last_pos = src;
      int numCount = 0;
      while (*src != 0 && *src != token) {
        src ++;
        numCount ++;
      }
      if (*src) { /* TODO: 解析出字符串就会创建动态内存，那么可能会有风险！ */
        *src = 0;
        token_val.ptr = malloc(sizeof(wchar_t) * (numCount + 1));
        *(wchar_t*)token_val.ptr = L'0';
        wcscpy((wchar_t*)token_val.ptr, last_pos);
        *src = token;
        src++;
      }
      token = Str;
      return;
    }

    /* == 和 = */
    else if (token == L'=') { 
      if (*src == L'=') {
        src++;
        token = Equal;
      }
      else {token = Assign;}
      return;
    }

    /* != */
    else if (token == L'!') {
      if (*src == L'=') {
        src++;
        token = Nequal;
      }
      return;
    }

    /* <= 或 < */
    else if (token == L'<') {
      if (*src == L'=') {
        src ++;
        token = LessEqual;
      }
      return;
    }

    /* >= 或 > */
    else if (token == L'>') {
      if (*src == L'=') {
        src++;
        token = GreatEqual;
      }
      return;
    }

    /* || */
    else if (token == L'|') {
      if (*src == L'|') {
        src++;
        token = OR;
      }
      return;
    }


    /* && */
    else if (token == L'&') {
      if ( *src == L'&') {
        src++;
        token=AND;
      }
      return;
    }

    /* 保持以在别处解析 */
    else if ( token == L'*' || token == L'/'  || token == L';' || token == L',' || token == L'+' || token == L'-' ||
        token == L'(' || token == L')' || token == L'{' || token == L'}' ||  token == L'[' || token == L']') {
        return;
    }

    /* 空格、制表符 */
    else if (token == L' ' || token == L'\t') {       }

    /* 不认识 */
    else {
        //wprintf(L"unexpected token: %d\n", token);
	printtovga(L"unexpected token\n");
    }
  }
}

static void clear(int level) {
	for (int i=symPointer-1; i>=0; i--) {
		token_val.ptr = &symtab[i];
		if ( token_val.ptr->levelNum >= level ) {
			clearThis();
		}
		else { break; }
	}
}

/* 20250827(QING): 在这里检测pointer联合字段是否为空，不为空就表明有值先释放 */
static void clearThis() {
  //printf("Clear a Symbol: %s\n", token_val.ptr->name);
  if (token_val.ptr->type == Str && token_val.ptr->pointer.funcp)
    free(token_val.ptr->pointer.funcp);  
  else if (token_val.ptr->type == ArraySym && token_val.ptr->pointer.list)
    free(token_val.ptr->pointer.list);
}

/* 检查是否匹配 */
static void match(int tk) {
  if (token == tk) {
    if (compileState==debug) {
      if (iswprint(tk)) { /* 该字符是否能够打印 */
        //wprintf(L"match: %lc\n", tk);
      }
      else {
        //wprintf(L"match: %d\n", tk);
	;
      }
    }
    next(); /* 检查下一个标记 */
  }
  else { /* 直接让程序死亡，在单片机上似乎不妥 */
    //wprintf(L"line %.*ls:expected token: %d\n", (int)(src - old_src), old_src,  tk);
    printtovga(L"unexpected token\n");
    __exit(-1);
    //clearThis(); 
  }
}

/*-------------------------- 语法分析与执行 --------------------------*/
static double term() {
  double temp = factor();
  while (token == L'*' || token == L'/') {
    if (token == L'*') {
      match(L'*');
      temp *= factor();
    }
    else {
      match(L'/');
      temp /= factor();
    }
  }
  return temp;
}

static double factor() {
  double temp = 0;
  if (token == L'(') {
    match(L'(');
    temp = expression();
    match(L')');
  }
  else if (token == Num || token == Char) {
    temp = token_val.val;
    match(token);
  }
  else if (token == Sym) {
    temp = token_val.ptr->value;
    match(Sym);
  }
  else if (token == ArraySym) {
    symbol *ptr = token_val.ptr;
    match(ArraySym);
    match(L'[');
    int index = (int)expression();
    if (index >= 0 && index < ptr->value) {
      temp = ptr->pointer.list[index].value;
    }
    match(L']');
  }
  else if (token == FuncSym) {	/* 处理函数调用 */
      temp = function();
  }
  else {
      //printf("Unknow token: %d.\n", token);
      printtovga(L"Unknow token\n");
  }
  return temp;
}

/* 加减法表达式 */
static double expression() {
  double temp = term();
  while (token == L'+' || token == L'-') {
    if (token == L'+') {
      match(L'+');
      temp += term();
    }
    else {
      match(L'-');
      temp -= term();
    }
  }
  return temp;
}


static int boolexp() {
    if (token == L'(') {
        match(L'(');
        int result = boolOR();
        match(L')');
        return result;
    }
    else if (token == L'!') {
        match(L'!');
        return boolexp();
    }
    double temp = expression();
    if (token == L'>') {
        match(L'>');
        return temp > expression();
    }
    else if (token == L'<') {
        match(L'<');
        return temp < expression();
    }
    else if (token == GreatEqual) {
        match(GreatEqual);
        return temp >= expression();
    }
    else if (token == LessEqual) {
        match(LessEqual);
        return temp <= expression();
    }
    else if (token == Equal) {
        match(Equal);
        return temp == expression();
    }
    return 0;
}

static void skipBoolExpr() {
    int count = 0;
    while (token && !(token == L')' && count == 0)) {
        if (token == L'(') count++;
        if (token == L')') count--;
        token = *src++;
    }
}


static int boolAND() {
    int val = boolexp();           
    while (token == AND) {
        match(AND);
        if (val == 0){
            skipBoolExpr();
            return 0;         // short cut
        }
        val = val & boolexp();
        if (val == 0) return 0;
    }
    return val;
}


static int boolOR() {
    int val = boolAND();
    while (token == OR) {
        match(OR);
        if (val == 1){
            skipBoolExpr();
            return 1;         // short cut
        }
        val = val | boolAND();
        if (val == 1) return 1;
    }
    return val;
}


static void skipStatments() {
    if(token == L'{')
        token = *src++;
    int count = 0;
    while (token && !(token == L'}' && count == 0)) {
        if (token == L'}') count++;
        if (token == L'{') count--;
        token = *src++;
    }
    match(L'}');
}

/* 解析一个句子 */
static double statement() {
    if (token == L'{') {
        match(L'{');
        while (token != L'}') {
            if (RETURNFLAG == statement()) 
                return RETURNFLAG;
        }
        match(L'}');
    }
    else if (token == If) {
        match(If);
        match(L'(');
        int boolresult = boolOR();
        match(L')');
        if (boolresult) {
            if (RETURNFLAG == statement()) 
                return RETURNFLAG;
        }
        else skipStatments();
        if (token == Else) {
            match(Else);
            if (!boolresult) {
                if (RETURNFLAG == statement())
                    return RETURNFLAG;
            }
            else skipStatments();
        }
    }
    else if (token == While) {
        match(While);
        wchar_t* whileStartPos = src;
        wchar_t* whileStartOldPos = old_src;
        int boolresult;
        do {
            src = whileStartPos;
            old_src = whileStartOldPos;
            token = L'('; /* 不加行会报错 */
            match(L'(');
            boolresult = boolOR();
            match(L')');
            if (boolresult) {
                if (RETURNFLAG == statement()) 
                    return RETURNFLAG;
            }
            else skipStatments();
        }while (boolresult);
    }


    /* ---- 给变量赋值 ---- */
    else if (token == Sym || token == ArraySym) {
        symbol* s = token_val.ptr;
        //clearThis(); 	/* 不知为何需要注释了才能跑 */
        int tktype = token;
        int index;
        match(tktype);
        if (tktype == ArraySym) {
            match(L'[');
            index = expression();
            match(L']');
            match(Assign);
            if (index >= 0 && index < s->value) {
                s->pointer.list[index].value = expression();
            }
	    /* TODO: 越界异常 */
        }
        else {
            match(Assign);
            if (token == Str) { 
                s->pointer.funcp = (wchar_t*)token_val.ptr;
                s->type = Str;
                match(Str);
            }
            else if (token == Char) {
                s->value = token_val.val;
                s->type = Char;
                match(Char);
            }
            else {
                s->value = expression();
                s->type = Num;
            }
        }
        match(L';');
    }
    else if (token == Array) {
        match(Array);
        symbol* s = token_val.ptr;
        //clearThis();
        match(Sym);
        match(L'(');
        int length = (int)expression();
        match(L')');
        s->pointer.list = malloc(sizeof(struct symStruct) * length + 1);
        for (int i = 0; i < length; ++i)
            s->pointer.list[i].type = Num;
        s->value = length;
        s->type = ArraySym;
        match(L';');
    }
    else if (token == Func) {
        match(Func);
        symbol* s = token_val.ptr;
        //clearThis();
        s->type = FuncSym;
        match(Sym);
        s->pointer.funcp = src;
        s->value = token;
        skipStatments();
        match(L';');
    }
    else if (token == Return) {
        match(Return);
        match(L'(');
        return_val = expression();
        match(L')');
        match(L';');
        return RETURNFLAG;
    }
    else if (token == Print || token == Read || token == Puts) {
        int func = token;
        double temp;
        match(func);
        match(L'(');
        switch (func) {
        case Print: 
            temp = expression();
	    wchar_t buf[16];
            swprintf(buf, 16, L"%lf\n", temp);
	    printtovga(buf);
            break;
        case Puts: 
            /* 这一句切换不过来 */
            //wprintf(L"%ls\n", (wchar_t*)token_val.ptr);
	    printtovga((wchar_t*)token_val.ptr);
            match(Str);
            break;
        case Read: /* 单片机上等下支持 */
            //wscanf(L"%lf", &token_val.ptr->value);
	    token_val.ptr->value = -1;
            token_val.ptr->type = Num;
            match(Sym);
        }
        match(L')');
        match(L';');
    }
    return 0;
}


static double function() {
    currentlevel++;
    return_val = 0;

    symbol* s = token_val.ptr;
    match(FuncSym);
    match(L'(');
    while (token != L')') {
        symtab[symPointer] = *token_val.ptr;
        wcscpy(symtab[symPointer].name, token_val.ptr->name);
        symtab[symPointer].levelNum = currentlevel;
        symPointer++;
        match(Sym);
        if (token == L',')
            match(L',');
    }
    match(L')');
    wchar_t* startPos = src;
    wchar_t* startOldPos = old_src;
    int startToken = token;
    old_src = src = s->pointer.funcp;
    token = (int)s->value;
    statement();
    src = startPos;
    old_src = startOldPos;
    token = startToken;

    while (symtab[symPointer - 1].levelNum == currentlevel) {
        symPointer--;
    }
    currentlevel--;
    return return_val;
}
/*----------------------------------------------------------------*/
int init_tryc() {

	/* 将所有字段赋值为0 */
	memset(symtab, 0, sizeof(symtab));

	int i;		/* 用于阅读定位 */
	src = L"array func else if return while print puts read";
	for (i = Array; i <= Read; ++i) {
		next();
		symtab[symPointer -1].type = i;
	}

	if (!(src = old_src = p_src = (wchar_t*)malloc(POOLSIZE))) {
		//wprintf(L"could not malloc(%d) for source area\n", POOLSIZE);
		printtovga(L"could not malloc for source aream\n");
		return -1;
	}

	top_src = 0;
	src[0] = L'\0'; // add EOF character
}

void free_tryc() {

	free(p_src);
}

int enqueue_tryc(wchar_t wc) {

	if (top_src >= POOLSIZE - 1) {
		return -1;
	}
	src[top_src] = wc;
	src[++top_src] = L'\0';
	return 0;
}

void eval_tryc() {

	if (*src == L'\0') return;

	next();
	while (token != L'\0') {
		statement();
	}
	src = p_src;

	top_src = 0;
	src[0]= L'\0';

}

void __exit() {
	while (1);
}

#ifdef _DEBUG
#include "fcntl.h"
#include "unistd.h"
#include "locale.h"
int main(int argc, char **argv)
{
    
	init_tryc();


    int i;
    setlocale(LC_ALL, "");
    wchar_t wc;
    i = 0;
    FILE *file = fopen(argv[1], "r");
    if (!file) {
        perror("fopen");
        return 1;
    }

    while ((wc = fgetwc(file)) != WEOF) {
        src[i++] = wc;
    }


    src[i] = L'\0'; // add EOF character
    fclose(file);

    eval_tryc();

    clear(0);
    free_tryc();

    return 0;
}
#endif
