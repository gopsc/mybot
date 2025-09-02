#include "cncc.h"
#include "cncc_map.h"
#include <stdio.h> 
#include <wchar.h>

/* 来源于网络，经过qing的整理
 * 20250902(qing): 修改以适配宽字符。 */
wchar_t * py_ime(const wchar_t *strInput_py_str) 
{ 
    int cpHZ, cpHZedge;
    char i,cInputStrLength, CmpStrLength; 
 
    cInputStrLength=wcslen(strInput_py_str);    /*输入拼音串长度*/ 
    if(*strInput_py_str==L'\0') return(L"");    /*如果输入空字符返回0*/ 
 
//    for(i=0;i<cInputStrLength;i++) 
//        *(strInput_py_str+i)|=0x20;             /*将字母串转为小写*/ 
 
    if(*strInput_py_str==L'i') return(L"");        /*错误拼音输入*/ 
    if(*strInput_py_str==L'u') return(L""); 
    if(*strInput_py_str==L'v') return(L""); 
 
    cpHZ=0;        /*查首字母索引*/ 
    cpHZedge=396;  /*设置指针界限*/ 
    while(cpHZ<cpHZedge)                         /*索引表不超界*/ 
    {
        if(0==wcscmp(strInput_py_str,code_table[cpHZ][0]))
            return code_table[cpHZ][1];    /*发现字母串不配,退出*/
        cpHZ++;
    } 

    return L"";                      /*无果而终*/ 
} 
