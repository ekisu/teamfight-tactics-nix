/* Offline regression for the legacy kernel32 timer-queue export.
 * Build for both PE architectures and run with the runtime under test.
 * No Riot files, authentication, or network access are used.
 */
#include <stdio.h>
#include <windows.h>

typedef HANDLE (WINAPI *set_timer_fn)(HANDLE, WAITORTIMERCALLBACK, void *, DWORD, DWORD, BOOL);

struct callback_state
{
    HANDLE event;
    LONG volatile count;
    LONG volatile not_timer;
};

static void CALLBACK callback(void *arg, BOOLEAN timer_fired)
{
    struct callback_state *state = arg;
    if (!timer_fired) InterlockedIncrement(&state->not_timer);
    InterlockedIncrement(&state->count);
    SetEvent(state->event);
}

static int check(int condition, const char *name)
{
    if (condition) return 0;
    fprintf(stderr, "FAIL: %s (error %lu)\n", name, GetLastError());
    return 1;
}

static int run_case(set_timer_fn set_timer, HANDLE queue, BOOL prefer_io)
{
    struct callback_state state = {0};
    HANDLE timer;
    int failed = 0, i;

    state.event = CreateEventA(NULL, FALSE, FALSE, NULL);
    if (!state.event) return check(0, "CreateEvent");
    timer = set_timer(queue, callback, &state, 1, 0, prefer_io);
    failed += check(timer != NULL, "SetTimerQueueTimer returns a timer handle");
    if (!timer)
    {
        CloseHandle(state.event);
        return failed;
    }
    failed += check(WaitForSingleObject(state.event, 3000) == WAIT_OBJECT_0, "one-shot callback");
    Sleep(80);
    failed += check(state.count == 1 && state.not_timer == 0, "one-shot context and timer flag");

    /* Windows does not rearm an already-expired one-shot timer. */
    failed += check(ChangeTimerQueueTimer(queue, timer, 1, 5), "update expired one-shot");
    Sleep(80);
    failed += check(state.count == 1, "expired one-shot is not rearmed");
    failed += check(DeleteTimerQueueTimer(queue, timer, INVALID_HANDLE_VALUE), "delete one-shot");

    state.count = state.not_timer = 0;
    ResetEvent(state.event);
    timer = set_timer(queue, callback, &state, 10000, 10000, prefer_io);
    failed += check(timer != NULL, "create periodic legacy timer");
    if (!timer)
    {
        CloseHandle(state.event);
        return failed;
    }
    failed += check(ChangeTimerQueueTimer(queue, timer, 1, 5), "periodic legacy timer");
    for (i = 0; i < 30 && state.count < 5; ++i)
        WaitForSingleObject(state.event, 100);
    failed += check(state.count >= 5 && state.not_timer == 0, "periodic callbacks");
    failed += check(DeleteTimerQueueTimer(queue, timer, INVALID_HANDLE_VALUE), "synchronous timer deletion");
    i = state.count;
    Sleep(80);
    failed += check(state.count == i, "no callback after deletion");
    CloseHandle(state.event);
    return failed;
}

int main(void)
{
    HMODULE module = GetModuleHandleA("kernel32.dll");
    union { FARPROC address; set_timer_fn timer; } function;
    set_timer_fn set_timer;
    HANDLE queue;
    int failed = 0;

    function.address = GetProcAddress(module, "SetTimerQueueTimer");
    set_timer = function.timer;
    if (!set_timer) return check(0, "SetTimerQueueTimer export");
    failed += run_case(set_timer, NULL, FALSE);
    failed += run_case(set_timer, NULL, TRUE);
    queue = CreateTimerQueue();
    failed += check(queue != NULL, "CreateTimerQueue");
    if (queue)
    {
        failed += run_case(set_timer, queue, FALSE);
        failed += run_case(set_timer, queue, TRUE);
        failed += check(DeleteTimerQueueEx(queue, INVALID_HANDLE_VALUE), "synchronous queue deletion");
    }
    if (!failed) puts("PASS: legacy timer creation, default/explicit queues, both PreferIo modes, reschedule, periodic execution, deletion");
    return failed ? 1 : 0;
}
