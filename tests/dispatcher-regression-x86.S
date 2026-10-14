.text
.globl _review_x86_fault, _review_x86_ip, _review_x86_resume
.def _review_x86_fault; .scl 2; .type 32; .endef
_review_x86_fault:
pushl %ebx
pushl %ebp
pushl %esi
pushl %edi
movl 20(%esp),%ecx
movl $0x11223301,%ebx
movl $0x11223302,%ebp
movl $0x11223303,%esi
movl $0x11223304,%edi
_review_x86_ip:
movb (%ecx),%al
_review_x86_resume:
xorl %eax,%eax
cmpl $0x11223301,%ebx
jne .Lx86_fail
cmpl $0x11223302,%ebp
jne .Lx86_fail
cmpl $0x11223303,%esi
jne .Lx86_fail
cmpl $0x11223304,%edi
jne .Lx86_fail
jmp .Lx86_done
.Lx86_fail:
movl $1,%eax
.Lx86_done:
popl %edi
popl %esi
popl %ebp
popl %ebx
ret
