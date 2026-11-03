#!/usr/bin/env python3
"""Patch the WebKit ANGLE checkout so its per-thread state does NOT live in
pthread keys.

Why
---
ANGLE on Apple platforms keeps three per-thread objects in *pthread keys*
instead of `thread_local`, as a workaround for an old dyld memory bug
(anglebug 42264979 / webkit bug 228240):

  * `egl::Thread*`            - global_state.cpp  (GetCurrentThreadTLS)
  * `gl::Context*` (valid)    - Context.cpp       (GetCurrentValidContextTLS)
  * `egl::TLSData*`           - Display.cpp       (GetDisplayTLS)

`angle::SetTLSValue()` ignores `pthread_setspecific`'s return value and its
`ASSERT` is compiled out in Release. So if ANY OTHER code in the process
deletes the pthread key index ANGLE holds (`pthread_key_delete`, directly or
via a library teardown that frees keys), every subsequent store silently
vanishes and `GetCurrentThreadTLS()` returns NULL forever after. ANGLE then
NULL-derefs at several *unchecked* sites, e.g.

    gl::GetGlobalContext()      -> currentThread->getContext()   (+0x18)
    egl::SetContextCurrent()    -> currentThread->setCurrent(..)

which is exactly the visionOS content-reload SIGSEGV (fault address 0x18,
`gl::GenerateContextLostErrorOnCurrentGlobalContext + 28`).

The fix is to select ANGLE's own already-supported alternative: real C++
`thread_local` variables, which no other library can delete. ANGLE ships that
path as `ANGLE_USE_STATIC_THREAD_LOCAL_VARIABLES`, but the Apple pthread path
wins the `#if` ladder, so the guards are flipped here.

Two unchecked derefs are additionally NULL-hardened as a second layer.

Idempotent: re-running is a no-op. Every substitution asserts its match count.
"""
import sys
import pathlib

ANGLE = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "").resolve()
if not (ANGLE / "src" / "libGLESv2" / "global_state.cpp").is_file():
    sys.exit(f"not an ANGLE source tree: {ANGLE}")

MARK = "RA_ANGLE_STATIC_TLS"


def edit(relpath, subs):
    p = ANGLE / relpath
    text = p.read_text()
    if MARK in text:
        print(f"  {relpath}: already patched")
        return
    for old, new, count in subs:
        n = text.count(old)
        if n != count:
            sys.exit(f"{relpath}: expected {count} match(es) of\n---\n{old}\n---\ngot {n}")
        text = text.replace(old, new)
    p.write_text(text)
    print(f"  {relpath}: patched")


TODO = ("// TODO(http://anglebug.com/42264979): Due to a bug in Apple's dyld loader,"
        " `thread_local` will\n")
APPLE_GUARD = "#if defined(ANGLE_PLATFORM_APPLE)\n" + TODO
STATIC_GUARD_HEAD = (
    "/* " + MARK + ": pthread-key TLS is deletable by any other library in the\n"
    " * process; a dead key silently swallows every store and ANGLE then NULL-\n"
    " * derefs its per-thread state. Use real thread_local instead. */\n"
    "#ifndef " + MARK + "\n"
    "#    define " + MARK + " 1\n"
    "#endif\n"
    "#if defined(ANGLE_PLATFORM_APPLE) && !defined(" + MARK + ")\n"
)
STATIC_GUARD = STATIC_GUARD_HEAD + TODO

# 1. egl::Thread* TLS
edit(
    "src/libGLESv2/global_state.cpp",
    [
        (APPLE_GUARD, STATIC_GUARD, 1),
        (
            "#elif defined(ANGLE_USE_STATIC_THREAD_LOCAL_VARIABLES)\n"
            "static thread_local Thread *gCurrentThread = nullptr;",
            "#elif defined(ANGLE_USE_STATIC_THREAD_LOCAL_VARIABLES) || defined(" + MARK + ")\n"
            "static thread_local Thread *gCurrentThread = nullptr;",
            1,
        ),
        # Second layer: never store through a NULL thread.
        (
            "    ASSERT(currentThread);\n"
            "    currentThread->setCurrent(context);",
            "    ASSERT(currentThread);\n"
            "    if (currentThread == nullptr)  /* " + MARK + " */\n"
            "    {\n"
            "        return;\n"
            "    }\n"
            "    currentThread->setCurrent(context);",
            1,
        ),
    ],
)

# 2. gl::Context* (current valid context) TLS
edit(
    "src/libANGLE/Context.cpp",
    [
        (APPLE_GUARD, STATIC_GUARD, 1),
        (
            "#elif defined(ANGLE_USE_STATIC_THREAD_LOCAL_VARIABLES)\n"
            "static thread_local Context *gCurrentValidContext = nullptr;",
            "#elif defined(ANGLE_USE_STATIC_THREAD_LOCAL_VARIABLES) || defined(" + MARK + ")\n"
            "static thread_local Context *gCurrentValidContext = nullptr;",
            1,
        ),
    ],
)

# 3. egl::TLSData* (Display) TLS. Two guards: the impl and Display::InitTLS.
edit(
    "src/libANGLE/Display.cpp",
    [
        (APPLE_GUARD, STATIC_GUARD, 1),
        (
            "#if defined(ANGLE_PLATFORM_APPLE)\n    SetDisplayTLS(tlsData);",
            "#if defined(ANGLE_PLATFORM_APPLE) && !defined(" + MARK + ")\n"
            "    SetDisplayTLS(tlsData);",
            1,
        ),
    ],
)

# 4. Second layer: gl::GetGlobalContext() dereferences the thread unchecked.
edit(
    "src/libGLESv2/global_state.h",
    [
        (
            "    ASSERT(currentThread);\n"
            "    return currentThread->getContext();",
            "    ASSERT(currentThread);\n"
            "    if (currentThread == nullptr)  /* " + MARK + " */\n"
            "    {\n"
            "        return nullptr;\n"
            "    }\n"
            "    return currentThread->getContext();",
            1,
        ),
    ],
)

# ---------------------------------------------------------------------------
# the same pthread-key disease in two more places, found after the
# on-device run crashed on the **ANGLE-Worker** thread in
#   sh::TVector<TIntermNode*>::operator new -> sh::TSymbolTable::push
#   -> sh::TCompiler::compileTreeImpl -> rx::ShaderTranslateTask::translate
#   -> gl::CompileTask::runImpl -> angle::AsyncWorkerPool::threadLoop
# i.e. the shader translator's *global pool allocator*, which is per-thread
# state held in a pthread key exactly like the three above.
# ---------------------------------------------------------------------------

# 5. Translator global pool allocator (compiler/translator/PoolAlloc.cpp).
#
# `PoolIndex` is a pthread key. `TCompiler::compile()` does
# `TScopedPoolAllocator scopedAlloc;` -> `SetGlobalPoolAllocator(&mAllocator)`
# on whichever thread is compiling (the ANGLE async worker pool), then every
# translator allocation goes through
#   POOL_ALLOCATOR_NEW_DELETE  ->  GetGlobalPoolAllocator()->allocate(s)
# (Common.h:47/59, ImmutableStringBuilder.h:73, PoolAlloc.h:110) with NO null
# check anywhere. If the key index is dead the store silently vanishes and the
# very next `operator new` dereferences NULL -> the worker-thread SIGSEGV.
#
# Split the one pthread key into what it was actually doing:
#   * a process-wide "translator initialised" flag (ShInitialize/ShFinalize),
#     which was never per-thread state at all; and
#   * a real `thread_local` pointer for the per-thread current pool.
# Second layer: GetGlobalPoolAllocator() can no longer return NULL -- it falls
# back to a thread_local pool of its own rather than handing back a pointer
# every caller immediately dereferences.
edit(
    "src/compiler/translator/PoolAlloc.cpp",
    [
        (
            "angle::TLSIndex PoolIndex = TLS_INVALID_INDEX;\n"
            "\n"
            "bool InitializePoolIndex()\n"
            "{\n"
            "    ASSERT(PoolIndex == TLS_INVALID_INDEX);\n"
            "\n"
            "    PoolIndex = angle::CreateTLSIndex(nullptr);\n"
            "    return PoolIndex != TLS_INVALID_INDEX;\n"
            "}\n"
            "\n"
            "void FreePoolIndex()\n"
            "{\n"
            "    ASSERT(PoolIndex != TLS_INVALID_INDEX);\n"
            "\n"
            "    angle::DestroyTLSIndex(PoolIndex);\n"
            "    PoolIndex = TLS_INVALID_INDEX;\n"
            "}\n"
            "\n"
            "bool IsGlobalPoolAllocatorInitialized()\n"
            "{\n"
            "    return PoolIndex != TLS_INVALID_INDEX;\n"
            "}\n"
            "\n"
            "angle::PoolAllocator *GetGlobalPoolAllocator()\n"
            "{\n"
            "    ASSERT(PoolIndex != TLS_INVALID_INDEX);\n"
            "    return static_cast<angle::PoolAllocator *>(angle::GetTLSValue(PoolIndex));\n"
            "}\n"
            "\n"
            "void SetGlobalPoolAllocator(angle::PoolAllocator *poolAllocator)\n"
            "{\n"
            "    ASSERT(PoolIndex != TLS_INVALID_INDEX);\n"
            "    angle::SetTLSValue(PoolIndex, poolAllocator);\n"
            "}\n",
            "angle::TLSIndex PoolIndex = TLS_INVALID_INDEX;\n"
            "\n"
            "/* " + MARK + ": the translator's per-thread pool allocator used to\n"
            " * live in the pthread key `PoolIndex`. A dead key index silently swallowed\n"
            " * every SetGlobalPoolAllocator() and the next POOL_ALLOCATOR_NEW_DELETE\n"
            " * dereferenced NULL on the ANGLE-Worker thread. Split it into a real\n"
            " * process-wide init flag plus a real thread_local pointer. */\n"
            "namespace\n"
            "{\n"
            "// Process-wide: set by ShInitialize(), cleared by ShFinalize(). Never was\n"
            "// per-thread state -- only the *value* below is.\n"
            "bool gPoolIndexInitialized = false;\n"
            "// Per-thread: the pool the compiling thread is currently allocating from.\n"
            "thread_local angle::PoolAllocator *gGlobalPoolAllocator = nullptr;\n"
            "}  // anonymous namespace\n"
            "\n"
            "bool InitializePoolIndex()\n"
            "{\n"
            "    gPoolIndexInitialized = true;\n"
            "    return true;\n"
            "}\n"
            "\n"
            "void FreePoolIndex()\n"
            "{\n"
            "    gPoolIndexInitialized = false;\n"
            "}\n"
            "\n"
            "bool IsGlobalPoolAllocatorInitialized()\n"
            "{\n"
            "    return gPoolIndexInitialized;\n"
            "}\n"
            "\n"
            "angle::PoolAllocator *GetGlobalPoolAllocator()\n"
            "{\n"
            "    if (gGlobalPoolAllocator == nullptr)  /* " + MARK + " second layer */\n"
            "    {\n"
            "        // Every caller dereferences the result unchecked, so never hand back\n"
            "        // NULL: allocate out of a per-thread fallback pool instead. Only\n"
            "        // reachable if a compile runs outside a TScopedPoolAllocator scope.\n"
            "        static thread_local angle::PoolAllocator sFallbackPool;\n"
            "        return &sFallbackPool;\n"
            "    }\n"
            "    return gGlobalPoolAllocator;\n"
            "}\n"
            "\n"
            "void SetGlobalPoolAllocator(angle::PoolAllocator *poolAllocator)\n"
            "{\n"
            "    gGlobalPoolAllocator = poolAllocator;\n"
            "}\n",
            1,
        ),
    ],
)

# 6. angle::GetCurrentThreadUniqueId() (common/system_utils.cpp).
#
# The Apple branch open-codes the same pattern with a raw pthread key (no
# angle::TLSIndex wrapper): dispatch_once pthread_key_create, then
# pthread_getspecific/pthread_setspecific with the return value ASSERTed only.
# A dead key index does not crash here -- pthread_getspecific just keeps
# returning NULL, so every call mints a *new* serial and the "unique thread id"
# stops identifying a thread. The non-Apple branch immediately below it is
# already exactly `thread_local uint64_t`; flip the guard onto it.
edit(
    "src/common/system_utils.cpp",
    [
        (
            "#if defined(ANGLE_PLATFORM_APPLE)\n"
            "// https://anglebug.com/42264979, similar to egl::GetCurrentThread()"
            " in libGLESv2/global_state.cpp\n",
            STATIC_GUARD_HEAD
            + "// https://anglebug.com/42264979, similar to egl::GetCurrentThread()"
            " in libGLESv2/global_state.cpp\n",
            1,
        ),
    ],
)

print("ANGLE static-TLS patch applied.")
