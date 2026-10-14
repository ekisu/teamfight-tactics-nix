.text
.macro OWN_LEAF name, fault, resume
.globl \name, \fault, \resume
.def \name; .scl 2; .type 32; .endef
.seh_proc \name
\name:
.seh_endprologue
\fault:
movb (%rcx),%al
\resume:
ret
.seh_endproc
.endm
OWN_LEAF review_fault_outer, review_outer_ip, review_outer_resume
OWN_LEAF review_fault_inner, review_inner_ip, review_inner_resume

.globl review_df_fault, review_df_ip, review_df_resume
.def review_df_fault; .scl 2; .type 32; .endef
.seh_proc review_df_fault
review_df_fault:
.seh_endprologue
std
review_df_ip:
movb (%rcx),%al
review_df_resume:
cld
ret
.seh_endproc

.globl review_nonvol_fault, review_nonvol_ip, review_nonvol_resume
.def review_nonvol_fault; .scl 2; .type 32; .endef
.seh_proc review_nonvol_fault
review_nonvol_fault:
pushq %rbx
.seh_pushreg %rbx
pushq %rbp
.seh_pushreg %rbp
pushq %rsi
.seh_pushreg %rsi
pushq %rdi
.seh_pushreg %rdi
pushq %r12
.seh_pushreg %r12
pushq %r13
.seh_pushreg %r13
pushq %r14
.seh_pushreg %r14
pushq %r15
.seh_pushreg %r15
subq $0x28,%rsp
.seh_stackalloc 0x28
.seh_endprologue
movabsq $0x1122334455667701,%rbx
movabsq $0x1122334455667702,%rbp
movabsq $0x1122334455667703,%rsi
movabsq $0x1122334455667704,%rdi
movabsq $0x1122334455667705,%r12
movabsq $0x1122334455667706,%r13
movabsq $0x1122334455667707,%r14
movabsq $0x1122334455667708,%r15
review_nonvol_ip:
movb (%rcx),%al
review_nonvol_resume:
xorl %eax,%eax
.macro CHECK_NV reg,value
movabsq $\value,%r10
cmpq %r10,\reg
jne .Lnv_fail
.endm
CHECK_NV %rbx,0x1122334455667701
CHECK_NV %rbp,0x1122334455667702
CHECK_NV %rsi,0x1122334455667703
CHECK_NV %rdi,0x1122334455667704
CHECK_NV %r12,0x1122334455667705
CHECK_NV %r13,0x1122334455667706
CHECK_NV %r14,0x1122334455667707
CHECK_NV %r15,0x1122334455667708
jmp .Lnv_done
.Lnv_fail:
movl $1,%eax
.Lnv_done:
addq $0x28,%rsp
popq %r15
popq %r14
popq %r13
popq %r12
popq %rdi
popq %rsi
popq %rbp
popq %rbx
ret
.seh_endproc

.globl review_seh_outer, review_seh_resume
.def review_seh_outer; .scl 2; .type 32; .endef
.seh_proc review_seh_outer
review_seh_outer:
pushq %rbx
.seh_pushreg %rbx
subq $0x20,%rsp
.seh_stackalloc 0x20
.seh_endprologue
.seh_handler review_outer_handler, @except, @unwind
call review_seh_inner
movl $0xbad,%eax
review_seh_resume:
addq $0x20,%rsp
popq %rbx
ret
.seh_endproc

.globl review_seh_inner, review_seh_ip
.def review_seh_inner; .scl 2; .type 32; .endef
.seh_proc review_seh_inner
review_seh_inner:
pushq %rbp
.seh_pushreg %rbp
subq $0x20,%rsp
.seh_stackalloc 0x20
.seh_endprologue
.seh_handler review_inner_handler, @except, @unwind
review_seh_ip:
movb (%rcx),%al
addq $0x20,%rsp
popq %rbp
ret
.seh_endproc
