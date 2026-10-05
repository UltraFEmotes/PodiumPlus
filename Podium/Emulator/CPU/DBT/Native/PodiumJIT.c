#include "PodiumJIT.h"

#include <TargetConditionals.h>
#include <errno.h>
#include <mach/mach.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define CS_DEBUGGED 0x10000000
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

bool podium_jit_debugger_attached(void) {
    unsigned int flags = 0;
    return csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED) != 0;
}

/// The last allocation failure, for the UI. Written once per failed call;
/// callers only ever read it, so no locking.
static char last_error[256];

const char *podium_jit_last_error(void) {
    return last_error;
}

static void record_error(const char *message) {
    snprintf(last_error, sizeof(last_error), "%s", message);
}

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR

// StikDebug's JIT26 protocol: `brk #0xf00d` with the command in x16.
// Command 1 prepares [x0, x0 + x1) as executable memory the process may
// fill in (TXM won't let it otherwise); command 0 detaches the debugger.
__attribute__((noinline, optnone))
static void jit26_prepare_region(void *address, size_t length) {
    __asm__ volatile("mov x0, %0\n"
                     "mov x1, %1\n"
                     "mov x16, #1\n"
                     "brk #0xf00d\n"
                     :: "r"(address), "r"(length) : "x0", "x1", "x16", "memory");
}

__attribute__((noinline, optnone))
static void jit26_detach(void) {
    __asm__ volatile("mov x16, #0\n"
                     "brk #0xf00d\n"
                     ::: "x16", "memory");
}

// If nothing services the breakpoint (no debugger, or one without the
// script), it arrives as SIGTRAP; this turns that into a failed request
// instead of a crash.
static sigjmp_buf trap_jump;

static void on_trap(int signal) {
    (void)signal;
    siglongjmp(trap_jump, 1);
}

static bool guarded(void (*body)(void *, size_t), void *address, size_t length) {
    struct sigaction handler, previous;
    memset(&handler, 0, sizeof(handler));
    handler.sa_handler = on_trap;
    sigemptyset(&handler.sa_mask);
    sigaction(SIGTRAP, &handler, &previous);
    bool ok = false;
    if (sigsetjmp(trap_jump, 1) == 0) {
        body(address, length);
        ok = true;
    }
    sigaction(SIGTRAP, &previous, NULL);
    return ok;
}

static void detach_body(void *address, size_t length) {
    (void)address;
    (void)length;
    jit26_detach();
}

#endif

void *podium_jit_allocate(size_t size, void **writable, PodiumJITMode *mode) {
    *writable = NULL;
    *mode = PodiumJITModeNone;

    void *rwx = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (rwx != MAP_FAILED) {
        *writable = rwx;
        *mode = PodiumJITModeRWX;
        last_error[0] = '\0';
        fprintf(stderr, "[podium-jit] RWX MAP_JIT region at %p, %zu bytes\n", rwx, size);
        return rwx;
    }
    {
        char message[256];
        snprintf(message, sizeof(message), "RWX MAP_JIT refused (errno %d)", errno);
        record_error(message);
        fprintf(stderr, "[podium-jit] %s\n", message);
    }

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (!podium_jit_debugger_attached()) {
        record_error("no debugger attached; launch from StikDebug for JIT");
        fprintf(stderr, "[podium-jit] no debugger attached; no JIT\n");
        return NULL;
    }
    void *executable = mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (executable == MAP_FAILED) {
        record_error("executable region refused by the kernel");
        fprintf(stderr, "[podium-jit] RX region refused (errno %d)\n", errno);
        return NULL;
    }
    if (!guarded(jit26_prepare_region, executable, size)) {
        record_error("debugger didn't prepare the region (StikDebug JIT script missing?)");
        fprintf(stderr, "[podium-jit] the debugger didn't prepare the region (no JIT26 script?)\n");
        munmap(executable, size);
        return NULL;
    }
    guarded(detach_body, NULL, 0);

    vm_address_t alias = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t result = vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                    (vm_address_t)executable, false, &current, &maximum, VM_INHERIT_DEFAULT);
    if (result != KERN_SUCCESS || mprotect((void *)alias, size, PROT_READ | PROT_WRITE) != 0) {
        record_error("writable alias for the region failed");
        fprintf(stderr, "[podium-jit] writable alias failed (kr %d, errno %d)\n", result, errno);
        if (result == KERN_SUCCESS) vm_deallocate(mach_task_self(), alias, size);
        munmap(executable, size);
        return NULL;
    }
    *writable = (void *)alias;
    *mode = PodiumJITModeDualMapped;
    last_error[0] = '\0';
    fprintf(stderr, "[podium-jit] dual-mapped region: runs at %p, written at %p, %zu bytes\n", executable, (void *)alias, size);
    return executable;
#else
    record_error("JIT needs a real iOS device (or macOS); not the simulator");
    return NULL;
#endif
}
