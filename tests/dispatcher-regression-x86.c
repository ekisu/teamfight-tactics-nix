/* Owned genuine x86 hardware exception, expected to run under new WoW64. */
#define _WIN32_WINNT 0x0601
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

#ifdef _WIN64
#error x86 fixture only
#endif

extern int review_x86_fault(const void *);
extern const BYTE review_x86_ip[], review_x86_resume[];
static void *page;
static DWORD thread;
static int callbacks,bad,active;

static LONG CALLBACK veh(EXCEPTION_POINTERS *p)
{
    unsigned flags;
    CONTEXT *c;
    if(!active || !p || !p->ExceptionRecord || !(c=p->ContextRecord) ||
       GetCurrentThreadId()!=thread ||
       p->ExceptionRecord->ExceptionCode!=EXCEPTION_ACCESS_VIOLATION ||
       p->ExceptionRecord->ExceptionAddress!=(void *)review_x86_ip ||
       c->Eip!=(ULONG_PTR)review_x86_ip ||
       p->ExceptionRecord->NumberParameters!=2 ||
       p->ExceptionRecord->ExceptionInformation[0]!=0 ||
       p->ExceptionRecord->ExceptionInformation[1]!=(ULONG_PTR)page)
    {
        ++bad;
        return EXCEPTION_CONTINUE_SEARCH;
    }
    ++callbacks;
    __asm__ volatile("pushfl; popl %0" : "=r"(flags) : : "memory");
    if((flags&0x400) || (c->ContextFlags&CONTEXT_CONTROL)!=CONTEXT_CONTROL ||
       c->Ebx!=0x11223301 || c->Ebp!=0x11223302 ||
       c->Esi!=0x11223303 || c->Edi!=0x11223304) ++bad;
    c->Eip=(ULONG_PTR)review_x86_resume;
    return EXCEPTION_CONTINUE_EXECUTION;
}

int main(void)
{
    BOOL wow=FALSE;
    PVOID h;
    int i,ok,removed,freed;
    thread=GetCurrentThreadId();
    if(!IsWow64Process(GetCurrentProcess(),&wow)) return 77;
    printf("case=x86_wow64_process PASS=%d pointer_size=%u is_wow64=%u\n",
           sizeof(void *)==4 && wow,(unsigned)sizeof(void *),(unsigned)wow);
    if(!wow) return 77;
    page=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);
    if(!page || !(h=AddVectoredExceptionHandler(1,veh))) return 77;
    active=1;
    for(i=0;i<16;++i) if(review_x86_fault(page)) ++bad;
    active=0;
    ok=callbacks==16 && !bad;
    printf("case=x86_real_av_context_resume PASS=%d callbacks=%d bad=%d\n",ok,callbacks,bad);
    removed=RemoveVectoredExceptionHandler(h)!=0;
    freed=VirtualFree(page,0,MEM_RELEASE)!=0;
    printf("case=cleanup PASS=%d removed=%d freed=%d\n",removed&&freed,removed,freed);
    ok &= removed&&freed;
    printf("suite=dispatcher_review_x86 result=%d\n",ok?0:1);
    return ok?0:1;
}
