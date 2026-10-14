/* Read-only public x64 NTDLL dispatcher layout control, separate from behavior.
 * Reads only the first 80 code bytes of the current process's published export.
 * Never follows/writes a hook pointer, patches code, or calls the dispatcher.
 * Native Windows19045 reference: short JZ 74 0f, two MOV+ADD argument setups,
 * dispatch CALL at0x29. This layout assertion is separate from API behavior.
 */
#define _WIN32_WINNT 0x0600
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if !defined(_WIN64) || !defined(__x86_64__)
#error This fixture requires an x86-64 MinGW target.
#endif

int main(void)
{
    HMODULE module = GetModuleHandleW(L"ntdll.dll");
    const BYTE *dispatcher;
    MEMORY_BASIC_INFORMATION info, after_info;
    BYTE code[80], again[80];
    SIZE_T copied = 0, copied_again = 0;
    unsigned i, prefix, test_rax, near_jz, short_jz, native_branch, setup, call29, unchanged;
    int branch_decoded = 0, branch_target = -1, result = 77;
    int32_t displacement;

    if (!module || !(dispatcher = (const BYTE *)GetProcAddress(module, "KiUserExceptionDispatcher")))
        goto unavailable;
    if (VirtualQuery(dispatcher, &info, sizeof(info)) != sizeof(info) ||
        info.Type != MEM_IMAGE || info.AllocationBase != module ||
        info.State != MEM_COMMIT || (info.Protect & (PAGE_GUARD | PAGE_NOACCESS)))
        goto unavailable;
    if (!ReadProcessMemory(GetCurrentProcess(), dispatcher, code, sizeof(code), &copied) ||
        copied != sizeof(code)) goto unavailable;
    printf("case=public_ntdll_export PASS=1 bytes_read=%llu type=%lu protect=%lu "
           "owner_is_ntdll=%u\n", (unsigned long long)copied, info.Type,
           info.Protect, (unsigned)(info.AllocationBase == module));
    printf("case=dispatcher_bytes");
    for (i = 0; i < sizeof(code); ++i) printf(" b%02x=%u", i, (unsigned)code[i]);
    putchar('\n');

    /* Public Wine upstream test_exception_dispatcher uses this same prefix. */
    prefix = code[0] == 0xfc && code[1] == 0x48 && code[2] == 0x8b && code[3] == 0x05;
    test_rax = code[8] == 0x48 && code[9] == 0x85 && code[10] == 0xc0;
    near_jz = code[11] == 0x0f && code[12] == 0x84;
    short_jz = code[11] == 0x74;
    if (near_jz)
    {
        memcpy(&displacement, code + 13, sizeof(displacement));
        branch_target = 17 + displacement;
        branch_decoded = 1;
    }
    else if (short_jz)
    {
        branch_target = 13 + (int8_t)code[12];
        branch_decoded = 1;
    }
    call29 = code[0x29] == 0xe8;
    native_branch = short_jz && code[12] == 0x0f && branch_target == 0x1c;
    /* Both equivalent register-MOV encodings have the native three-byte size. */
    setup = code[0x0d] == 0x48 &&
            ((code[0x0e] == 0x89 && code[0x0f] == 0xe1) ||
             (code[0x0e] == 0x8b && code[0x0f] == 0xcc)) &&
            !memcmp(code + 0x10, "\x48\x81\xc1\xf0\x04\x00\x00", 7) &&
            code[0x1a] == 0xff && code[0x1b] == 0xd0 && code[0x1c] == 0x48 &&
            ((code[0x1d] == 0x89 && code[0x1e] == 0xe1) ||
             (code[0x1d] == 0x8b && code[0x1e] == 0xcc)) &&
            !memcmp(code + 0x1f, "\x48\x81\xc1\xf0\x04\x00\x00", 7);
    printf("case=cld_mov_prefix PASS=%u byte00=%u byte01=%u byte02=%u byte03=%u\n",
           prefix, (unsigned)code[0], (unsigned)code[1], (unsigned)code[2], (unsigned)code[3]);
    printf("case=test_rax PASS=%u byte08=%u byte09=%u byte0a=%u\n", test_rax,
           (unsigned)code[8], (unsigned)code[9], (unsigned)code[10]);
    printf("case=native_short_jz_layout PASS=%u near_jz=%u short_jz=%u byte0b=%u byte0c=%u "
           "branch_decoded=%u branch_target_offset=%d\n", native_branch, near_jz, short_jz,
            (unsigned)code[11], (unsigned)code[12], (unsigned)branch_decoded, branch_target);
    printf("case=native_mov_add_setup PASS=%u\n", setup);
    printf("case=call_at_29 PASS=%u byte29=%u byte25=%u call_at_25=%u\n", call29,
           (unsigned)code[0x29], (unsigned)code[0x25], (unsigned)(code[0x25] == 0xe8));

    if (!ReadProcessMemory(GetCurrentProcess(), dispatcher, again, sizeof(again), &copied_again) ||
        copied_again != sizeof(again) ||
        VirtualQuery(dispatcher, &after_info, sizeof(after_info)) != sizeof(after_info))
        goto unavailable;
    unchanged = !memcmp(code, again, sizeof(code)) &&
                after_info.Protect == info.Protect && after_info.Type == info.Type &&
                after_info.AllocationBase == info.AllocationBase;
    printf("case=public_source_unchanged PASS=%u bytes_read_again=%llu protect_after=%lu\n",
           unchanged, (unsigned long long)copied_again, after_info.Protect);
    result = prefix && test_rax && native_branch && setup && call29 && unchanged ? 0 : 1;
    printf("suite=dispatcher_layout result=%d\n", result);
    return result;

unavailable:
    printf("case=public_ntdll_unavailable PASS=0 win_error=%lu bytes_read=%llu\n",
           GetLastError(), (unsigned long long)copied);
    printf("suite=dispatcher_layout result=77\n");
    return 77;
}
