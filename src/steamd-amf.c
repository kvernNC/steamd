/*
 * libsteamd-amf : rend utilisable l'encodeur AMF de Steam Linux (seul chemin AV1
 * de Steam sur GPU AMD : son encodeur VA-API ne propose que HEVC et H264).
 * Chargée par LD_PRELOAD depuis steamd-launch (AMF_ENCODER=true).
 *
 * - Steam tourne dans pressure-vessel : libamfrt64 et libamdenc64 n'y sont pas dans
 *   le chemin de recherche. On les charge sous /run/host (hôte) ou tels quels (/opt).
 * - AMF ne crée d'encodeur que si son contexte a un device DX11, DX12, DX9 ou
 *   Vulkan, mais Steam Linux n'appelle que InitOpenCL() : on y ajoute
 *   InitVulkan(NULL), en patchant la vtable exportée de AMFContextImpl. Le device
 *   Vulkan (RADV) suffit : un échec d'OpenCL (pas d'OpenCL AMD) est masqué.
 *
 *   STEAMD_AMF_DIR=d1:d2    dossiers de libamfrt64 et libamdenc64 sur l'hôte (/usr/lib)
 *   STEAMD_AMF_DEBUG=1      journal sur stderr
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <glob.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* Slots de la vtable de amf::AMFContext2 (AMF 1.4, vérifiés sur libamfrt64 1.4.37) */
#define SLOT_INIT_OPENCL 22
#define SLOT_INIT_VULKAN 58
#define SLOT_GET_VULKAN_DEVICE 59

typedef void *(*dlopen_fn)(const char *, int);
typedef int (*init_fn)(void *, void *);
typedef void *(*get_device_fn)(void *);

static init_fn init_opencl;

static int debug(void)
{
    static int d = -1;
    if (d < 0) {
        const char *e = getenv("STEAMD_AMF_DEBUG");
        d = e && *e == '1';
    }
    return d;
}
#define LOG(...) do { if (debug()) fprintf(stderr, "steamd-amf: " __VA_ARGS__); } while (0)

static void *real_dlopen(const char *name, int flags)
{
    static dlopen_fn next;
    if (!next)
        next = (dlopen_fn)dlsym(RTLD_NEXT, "dlopen");
    return next ? next(name, flags) : NULL;
}

/* Premier fichier name* des dossiers d'AMF, vus du conteneur puis tels quels */
static void *open_amf(const char *name, int flags)
{
    static const char *const roots[] = { "/run/host", "" };
    const char *dirs = getenv("STEAMD_AMF_DIR");
    if (!dirs || !*dirs)
        dirs = "/usr/lib";
    for (const char *dir = dirs; *dir;) {
        size_t len = strcspn(dir, ":");
        for (size_t r = 0; r < sizeof(roots) / sizeof(*roots); r++) {
            char pattern[512];
            glob_t g;
            snprintf(pattern, sizeof(pattern), "%s%.*s/%s*", roots[r], (int)len, dir, name);
            if (glob(pattern, 0, NULL, &g) != 0)
                continue;
            void *h = NULL;
            for (size_t i = 0; i < g.gl_pathc && !h; i++)
                h = real_dlopen(g.gl_pathv[i], flags);
            if (!h)
                LOG("%s : %s\n", g.gl_pathv[0], dlerror());
            globfree(&g);
            if (h)
                return h;
        }
        dir += len + (dir[len] == ':');
    }
    return NULL;
}

static int hook_init_opencl(void *ctx, void *queue)
{
    int r = init_opencl(ctx, queue);
    void **vt = *(void ***)ctx;
    if (((get_device_fn)vt[SLOT_GET_VULKAN_DEVICE])(ctx)) {
        LOG("InitOpenCL -> %d, device Vulkan déjà présent\n", r);
        return r;
    }
    int v = ((init_fn)vt[SLOT_INIT_VULKAN])(ctx, NULL);
    LOG("InitOpenCL -> %d, InitVulkan -> %d\n", r, v);
    /* Steam abandonne AMF si InitOpenCL échoue, alors que l'encodeur n'utilise que Vulkan */
    return r != 0 && v == 0 ? 0 : r;
}

static void patch_context(void *amf)
{
    char *vtable = dlsym(amf, "_ZTV14AMFContextImpl");
    if (!vtable) {
        LOG("vtable de AMFContextImpl introuvable, contexte non modifié\n");
        return;
    }
    /* Les slots suivent le décalage vers le haut et le typeinfo */
    void **slot = (void **)(vtable + 2 * sizeof(void *)) + SLOT_INIT_OPENCL;
    if (*slot == (void *)hook_init_opencl)
        return;
    long page = sysconf(_SC_PAGESIZE);
    void *start = (void *)((uintptr_t)slot & ~(uintptr_t)(page - 1));
    if (mprotect(start, (size_t)page, PROT_READ | PROT_WRITE) != 0) {
        LOG("mprotect : échec, contexte non modifié\n");
        return;
    }
    init_opencl = (init_fn)*slot;
    *slot = (void *)hook_init_opencl;
    mprotect(start, (size_t)page, PROT_READ);
    LOG("InitOpenCL de AMFContextImpl intercepté\n");
}

/* AMF charge son moteur d'encodage par dlopen("libamdenc64.so"), nom sans version que
 * pressure-vessel ne fournit pas */
void *dlopen(const char *name, int flags)
{
    void *h = real_dlopen(name, flags);
    if (!h && name && !strcmp(name, "libamdenc64.so"))
        h = open_amf("libamdenc64.so", flags);
    return h;
}

/* Steam charge libamfrt64 par dlmopen(LM_ID_BASE, "libamfrt64.so.1") : chargée ici par son
 * chemin, elle est retrouvée par son soname. dlmopen n'est pas intercepté, car la recherche
 * par le RUNPATH de Steam ($ORIGIN) dépend de l'appelant. */
__attribute__((constructor)) static void preload_amf(void)
{
    if (strcmp(program_invocation_short_name, "steam") != 0)
        return;
    void *h = open_amf("libamfrt64.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (h)
        patch_context(h);
    else
        LOG("libamfrt64 introuvable (paquet amf-amdgpu-pro)\n");
}
