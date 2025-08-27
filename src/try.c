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
#include <setjmp.h>
#define POOLSIZE (16 * 1024)  /* 任意大小 */
#define SYMTABSIZE (1 * 1024) /* ！符号表栈的大小 */
#define MAXNAMESIZE 16        /* 变量/函数名称的长度 */
#define RETURNFLAG DBL_MAX    /* 表明函数中已经出现return语句 */

/* 该结构体表示存储在符号表中的一个符号 */
typedef struct symStruct {
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

/* 解释器状态枚举
 *
 * 20250827(qing): 使用int直接接受匿名枚举我第一次见
 */
enum {
  debug, run
};
static int compileState = run; /* 当前解释器状态 */

static double return_val = 0;  /* 用于保存函数的返回值 */

/* 标记和类别（运算符放最后并按优先级排序） */
enum {
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
/* ---------------- 跳转 ---------------- */

/* 保存跳转状态的全局变量 */
jmp_buf mainEnv;

/*--------------- 函数声明 ---------------*/
static double function();
static double statement();
static int boolOR();
static int boolAND();
static int boolexp();
static double expression();
static double factor();
static double term();
static void match(int tk);
static void next();
/////
static void clearThis();
/* -------------------  词法分析  -------------------*/

/* 输入字符串的下一个标记 */
static void next() {
  wchar_t *last_pos;
  while(token = *src) {
    ++src;
    if (token == L'\n') {           /* 新的一行 */
      if (compileState == debug)    /* 如果在调试模式，打印当前程序行 */
        wprintf(L"%.*ls", (int)(src-old_src), old_src);
      old_src = src;
    }
    else if (token == L'#') {       /* 跳过注释 */
      while(*src != 0 && *src != L'\n') {
        src++;
      }
    }
    /* 20250827(qing): 修改以适应中文标记 */
    else if ((token >= L'a' && token <= L'z') || (token >= L'A' && token <= L'Z') || (token == L'_') || (token > 0x7F)) {
      last_pos = src -1; /* 程序标识符 */
      wchar_t nameBuffer[MAXNAMESIZE];
      nameBuffer[0] = token;
      while ((*src >= L'a' && *src <= L'z') || (*src >= L'A' && *src <= L'Z') || (*src >= L'0' && *src <= L'9') || (*src == L'_') || (*src > 0x7f)) {
        nameBuffer[src-last_pos] = *src;
        src++;
      }
      nameBuffer[src-last_pos] = 0;   /* 获取标识符名 */
      int i;
      for (i=symPointer-1; i>=0; --i) { /* 在符号表中搜索符号 */
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
            // ？？？
            else {
              token = symtab[i].type;
              token_val.ptr = NULL; /* 以防万一，为当前记号存储器赋个值！因为Array记号可能到这里来，它会在检查失败后检查释放 */
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
    else if (token == L'\'') {  /* 解析字符 */
      token_val.val = *src++;
      token = Char;
      src++;
      return;
    }
    else if (token == L'"') { /* 解析字符串 */
      last_pos = src;
      int numCount = 0;
      while (*src != 0 && *src != token) {
        src ++;
        numCount ++;
      }
      if (*src) { /* 解析出字符串就会创建动态内存，那么可能会有风险！ */
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
    else if (token == L'=') { // 解析 '==' 和 '='
      if (*src == L'=') {
        src++;
        token = Equal;
      }
      return;
    }
    else if (token == L'!') { // 解析 '!='
      if (*src == L'=') {
        src++;
        token = Nequal;
      }
      return;
    }
    else if (token == L'<') { // 解析 '<=' 或 '<'
      if (*src == L'=') {
        src ++;
        token = LessEqual;
      }
      return;
    }
    else if (token == L'>') { // 解析 '>=' 或 '>'
      if (*src == L'=') {
        src++;
        token = GreatEqual;
      }
      return;
    }
    else if (token == L'|') { // '||'
      if (*src == L'|') {
        src++;
        token = OR;
      }
      return;
    }
    else if (token == L'&') { // '&&'
      if ( *src == L'&') {
        src++;
        token=AND;
      }
      return;
    }
    else if ( token == L'*' || token == L'/'  || token == L';' || token == L',' || token == L'+' || token == L'-' ||
        token == L'(' || token == L')' || token == L'{' || token == L'}' ||  token == L'[' || token == L']') {
        return;
    }
    else if (token == L' ' || token == L'\t') {        }
    else {
        wprintf(L"unexpected token: %d\n", token);
    }
  }
}

/* 20250827(QING): 在这里检测pointer联合字段是否为空，不为空就表明有值先释放 */
static void clearThis() {      
  if (token_val.ptr->type == Str && token_val.ptr->pointer.funcp)
    free(token_val.ptr->pointer.funcp);  
  else if (token_val.ptr->type == ArraySym && token_val.ptr->pointer.list)
    free(token_val.ptr->pointer.list);
}

/* 检查是否匹配 */
static void match(int tk) {
  if (token == tk) {
    if (compileState==debug) {
      if (iswprint(tk)) /* 该字符是否能够打印 */
        wprintf(L"match: %lc\n", tk);
      else
        wprintf(L"match: %d\n", tk);
    }
    next(); /* 检查下一个标记 */
  }
  else { /* 直接让程序死亡，似乎不妥 */
    wprintf(L"line %.*ls:expected token: %d\n", (int)(src - old_src), old_src,  tk);
    //exit(-1);
    clearThis(); /* 退出前先检查是否是堆内存类型，可能会出现意外情况 */
    longjmp(mainEnv, 1);
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
    else if (token == Sym || token == ArraySym) {
        symbol* s = token_val.ptr;
        clearThis();  
        int tktype = token;
        int index;
        match(tktype);
        if (tktype == ArraySym) {
            match(L'[');
            index = expression();
            match(L']');
            match(L'=');
            if (index >= 0 && index < s->value) {
                s->pointer.list[index].value = expression();
            }
        }
        else {
            match(L'=');
            if (token == Str) { /* 在这里加入字符串拼接的表达式？ */
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
        clearThis();
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
        clearThis();
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
            wprintf(L"%lf\n", temp);
            break;
        case Puts: 
            /* 这一句切换不过来 */
            wprintf(L"%ls\n", (wchar_t*)token_val.ptr);
            match(Str);
            break;
        case Read: /* 单片机上怎么弄？ */
            wscanf(L"%lf", &token_val.ptr->value);
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

int try()
{
    /* 将所有字段赋值为0 */
    memset(symtab, 0, sizeof(symtab));
    
    int i;
    src = L"array func else if return while print puts read";
    for (i = Array; i <= Read; ++i) {
        next();
        symtab[symPointer -1].type = i;
    }
    if (!(src = old_src = (wchar_t*)malloc(POOLSIZE))) {
        wprintf(L"could not malloc(%d) for source area\n", POOLSIZE);
        return -1;
    }

    src[0] = 0; // add EOF character
    wcscpy(src, L"ab = 1;\nccd = \"123\"; \nwhile(ab < 10) {\nab = ab + 1;\nputs(ccd);\n}\n");
    next();
    
    while (!setjmp(mainEnv) && token != 0) {
        statement();
    }

    return 0;
}

