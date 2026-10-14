/* Owned, offline exception fixtures. No NTDLL hooks or protected clients. */
#define _WIN32_WINNT 0x0601
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

#ifndef _WIN64
#error x64 fixture only
#endif

extern void review_fault_outer(const void *), review_fault_inner(const void *);
extern void review_df_fault(const void *);
extern int review_nonvol_fault(const void *), review_seh_outer(const void *);
extern const BYTE review_outer_ip[], review_outer_resume[];
extern const BYTE review_inner_ip[], review_inner_resume[];
extern const BYTE review_df_ip[], review_df_resume[];
extern const BYTE review_nonvol_ip[], review_nonvol_resume[];
extern const BYTE review_seh_ip[], review_seh_resume[];

static void *pages[2];
static DWORD owner_thread;
static int phase, depth, outer_count, inner_count, df_count, nonvol_count;
static int unexpected, live_df_bad, saved_df_bad, nonvol_bad;
static int seh_search_inner, seh_search_outer, seh_unwind_inner, seh_bad;
static unsigned seh_return;

typedef void (WINAPI *unwind_fn)(PVOID,PVOID,PEXCEPTION_RECORD,PVOID,PCONTEXT,PUNWIND_HISTORY_TABLE);
static unwind_fn unwind_ex;

static int owned_av(EXCEPTION_POINTERS *p, const BYTE *ip, const void *page)
{
    return p && p->ExceptionRecord && p->ContextRecord &&
           GetCurrentThreadId() == owner_thread &&
           p->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION &&
           p->ExceptionRecord->ExceptionAddress == (void *)ip &&
           p->ContextRecord->Rip == (ULONG_PTR)ip &&
           p->ExceptionRecord->NumberParameters == 2 &&
           p->ExceptionRecord->ExceptionInformation[0] == 0 &&
           p->ExceptionRecord->ExceptionInformation[1] == (ULONG_PTR)page;
}

static LONG CALLBACK review_veh(EXCEPTION_POINTERS *p)
{
    ULONG64 flags;
    __asm__ volatile("pushfq; popq %0" : "=r"(flags) : : "memory");
    if (flags & 0x400) ++live_df_bad;
    if (phase == 1 && depth == 0 && owned_av(p,review_outer_ip,pages[0]))
    {
        ++outer_count;
        depth=1;
        review_fault_inner(pages[1]); /* A genuinely nested second hardware AV. */
        depth=0;
        p->ContextRecord->Rip=(ULONG_PTR)review_outer_resume;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (phase == 1 && depth == 1 && owned_av(p,review_inner_ip,pages[1]))
    {
        ++inner_count;
        p->ContextRecord->Rip=(ULONG_PTR)review_inner_resume;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (phase == 2 && owned_av(p,review_df_ip,pages[0]))
    {
        ++df_count;
        if (!(p->ContextRecord->EFlags & 0x400)) ++saved_df_bad;
        p->ContextRecord->Rip=(ULONG_PTR)review_df_resume;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (phase == 3 && owned_av(p,review_nonvol_ip,pages[0]))
    {
        CONTEXT *c=p->ContextRecord;
        ++nonvol_count;
        if (c->Rbx!=0x1122334455667701ULL || c->Rbp!=0x1122334455667702ULL ||
            c->Rsi!=0x1122334455667703ULL || c->Rdi!=0x1122334455667704ULL ||
            c->R12!=0x1122334455667705ULL || c->R13!=0x1122334455667706ULL ||
            c->R14!=0x1122334455667707ULL || c->R15!=0x1122334455667708ULL)
            ++nonvol_bad;
        c->Rip=(ULONG_PTR)review_nonvol_resume;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (phase == 4 && owned_av(p,review_seh_ip,pages[0]))
        return EXCEPTION_CONTINUE_SEARCH; /* Normal PE-table SEH handles it. */
    ++unexpected;
    return EXCEPTION_CONTINUE_SEARCH;
}

EXCEPTION_DISPOSITION WINAPI review_inner_handler(EXCEPTION_RECORD *r, ULONG_PTR frame,
                                                  CONTEXT *c, DISPATCHER_CONTEXT *d)
{
    (void)frame; (void)c; (void)d;
    if (phase!=4 || r->ExceptionCode!=EXCEPTION_ACCESS_VIOLATION) ++seh_bad;
    if (r->ExceptionFlags & EXCEPTION_UNWINDING) ++seh_unwind_inner;
    else ++seh_search_inner;
    return ExceptionContinueSearch;
}

EXCEPTION_DISPOSITION WINAPI review_outer_handler(EXCEPTION_RECORD *r, ULONG_PTR frame,
                                                  CONTEXT *c, DISPATCHER_CONTEXT *d)
{
    if (phase!=4 || r->ExceptionCode!=EXCEPTION_ACCESS_VIOLATION) ++seh_bad;
    if (!(r->ExceptionFlags & EXCEPTION_UNWINDING))
    {
        ++seh_search_outer;
        /* Only unwind this fixture's ordinary owned PE stack frames. */
        unwind_ex((void *)frame,(void *)review_seh_resume,r,(void *)0x2468ace0,c,d->HistoryTable);
        ++seh_bad; /* RtlUnwindEx must transfer to our resume label. */
    }
    return ExceptionContinueSearch;
}

static int report(const char *name, int pass, int count1, int count2)
{
    printf("case=%s PASS=%d count1=%d count2=%d\n",name,pass,count1,count2);
    return pass;
}

static int metadata_case(void)
{
    BYTE *entry=(BYTE *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"KiUserExceptionDispatcher");
    DECLSPEC_ALIGN(16) BYTE stack[0x700]={0};
    CONTEXT c={0};
    DWORD64 image,frame;
    PVOID data=NULL;
    PRUNTIME_FUNCTION fn;
    int pass=1;
    static const unsigned offsets[]={0,8,0x0d,0x1c,0x29};
    unsigned i;
    if (!entry) return 0;
    fn=RtlLookupFunctionEntry((ULONG_PTR)entry,&image,NULL);
    if (!fn) return 0;
    /* Public documented x64 machine-frame layout in this Wine implementation. */
    *(ULONG64 *)(stack+0x590)=0x123456789abcdef0ULL;
    *(ULONG64 *)(stack+0x598)=0x33;
    *(ULONG64 *)(stack+0x5a0)=0x202;
    *(ULONG64 *)(stack+0x5a8)=0x2233445566778890ULL;
    *(ULONG64 *)(stack+0x5b0)=0x2b;
    *(ULONG64 *)(stack+0x90)=0x101;
    *(ULONG64 *)(stack+0xa0)=0x102;
    *(ULONG64 *)(stack+0xa8)=0x103;
    *(ULONG64 *)(stack+0xb0)=0x104;
    *(ULONG64 *)(stack+0xd8)=0x105;
    *(ULONG64 *)(stack+0xe0)=0x106;
    *(ULONG64 *)(stack+0xe8)=0x107;
    *(ULONG64 *)(stack+0xf0)=0x108;
    for(i=0;i<sizeof(offsets)/sizeof(offsets[0]);++i)
    {
        ZeroMemory(&c,sizeof(c));
        c.ContextFlags=CONTEXT_FULL;
        c.Rsp=(ULONG_PTR)stack;
        c.Rip=(ULONG_PTR)entry+offsets[i];
        RtlVirtualUnwind(UNW_FLAG_NHANDLER,image,c.Rip,fn,&c,&data,&frame,NULL);
        pass &= c.Rip==0x123456789abcdef0ULL && c.Rsp==0x2233445566778890ULL &&
                c.Rbx==0x101 && c.Rbp==0x102 && c.Rsi==0x103 && c.Rdi==0x104 &&
                c.R12==0x105 && c.R13==0x106 && c.R14==0x107 && c.R15==0x108;
    }
    return report("virtual_unwind_dispatcher",pass,(int)i,0);
}

int main(void)
{
    PVOID veh;
    int ok=1,i,removed,freed1,freed2;
    unsigned long long resumed_flags;
    owner_thread=GetCurrentThreadId();
    unwind_ex=(unwind_fn)(ULONG_PTR)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"RtlUnwindEx");
    pages[0]=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);
    pages[1]=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);
    if(!pages[0] || !pages[1] || !unwind_ex) return 77;
    veh=AddVectoredExceptionHandler(1,review_veh);
    if(!veh) return 77;
    for(i=0;i<8;++i)
    {
        phase=1;
        review_fault_outer(pages[0]);
        phase=2;
        review_df_fault(pages[0]);
        /* DF must have been cleared by our own resume instruction. */
        __asm__ volatile("pushfq; popq %0" : "=r"(resumed_flags) : : "memory");
        if(resumed_flags & 0x400) ++saved_df_bad;
        phase=3;
        if(review_nonvol_fault(pages[0])) ++nonvol_bad;
        phase=4;
        seh_return=(unsigned)review_seh_outer(pages[0]);
        if(seh_return!=0x2468ace0) ++seh_bad;
    }
    phase=0;
    ok &= report("nested_hardware_veh",outer_count==8 && inner_count==8 && !depth,outer_count,inner_count);
    ok &= report("df_live_clear_saved_preserved",df_count==8 && !live_df_bad && !saved_df_bad,df_count,live_df_bad+saved_df_bad);
    ok &= report("nonvolatile_context_and_resume",nonvol_count==8 && !nonvol_bad,nonvol_count,nonvol_bad);
    ok &= report("seh_search_and_unwind",seh_search_inner==8 && seh_search_outer==8 && seh_unwind_inner==8 && !seh_bad,seh_search_outer,seh_unwind_inner);
    ok &= report("unexpected_exceptions",!unexpected,unexpected,0);
    ok &= metadata_case();
    removed=RemoveVectoredExceptionHandler(veh)!=0;
    freed1=VirtualFree(pages[0],0,MEM_RELEASE)!=0;
    freed2=VirtualFree(pages[1],0,MEM_RELEASE)!=0;
    ok &= report("cleanup",removed && freed1 && freed2,removed,freed1+freed2);
    printf("suite=dispatcher_review_x64 result=%d\n",ok?0:1);
    return ok?0:1;
}
