/*
 * libsteamd-vaapi : impose à l'encodeur VA-API de Steam le contrôle de débit de
 * Sunshine sur GPU AMD (vaapi_strict_rc_buffer) : CBR et tampon HRD d'une seule
 * image, pour supprimer les pointes de débit. Chargée par LD_PRELOAD depuis
 * steamd-launch (VAAPI_STRICT_RC=true).
 *
 *   STEAMD_VA_FPS      fréquence utilisée tant que Steam n'a pas transmis la sienne (60)
 *   STEAMD_VA_QUALITY  niveau de qualité forcé si Steam en transmet un (vide : inchangé)
 *   STEAMD_VA_DEBUG=1  journal sur stderr
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <va/va.h>

typedef VAStatus (*create_config_fn)(VADisplay, VAProfile, VAEntrypoint, VAConfigAttrib *, int, VAConfigID *);
typedef VAStatus (*create_buffer_fn)(VADisplay, VAContextID, VABufferType, unsigned int, unsigned int, void *,
                                     VABufferID *);
typedef VAStatus (*map_buffer_fn)(VADisplay, VABufferID, void **);
typedef VAStatus (*unmap_buffer_fn)(VADisplay, VABufferID);

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t bps;                    /* dernier débit transmis (RateControl) */
static uint32_t fps_num, fps_den = 1;   /* dernière fréquence transmise (FrameRate) */
static VADisplay hrd_dpy;               /* tampon HRD créé avant la fréquence, à corriger */
static VABufferID hrd_buf = VA_INVALID_ID;

static int debug(void)
{
    static int d = -1;
    if (d < 0) {
        const char *e = getenv("STEAMD_VA_DEBUG");
        d = e && *e == '1';
    }
    return d;
}
#define LOG(...) do { if (debug()) fprintf(stderr, "steamd-vaapi: " __VA_ARGS__); } while (0)

static void *next_sym(const char *name)
{
    void *p = dlsym(RTLD_NEXT, name);
    if (!p)
        LOG("%s introuvable\n", name);
    return p;
}

/* Tampon d'une image : débit / fréquence, rempli aux 3/4 comme le fait ffmpeg */
static void patch_hrd(VAEncMiscParameterHRD *hrd)
{
    uint32_t num, den, rate;
    pthread_mutex_lock(&lock);
    rate = bps;
    num = fps_num;
    den = fps_den;
    pthread_mutex_unlock(&lock);
    if (!num) {
        const char *e = getenv("STEAMD_VA_FPS");
        num = e && atoi(e) > 0 ? (uint32_t)atoi(e) : 60;
        den = 1;
    }
    if (!rate)
        return;
    uint32_t size = (uint32_t)((uint64_t)rate * den / num);
    LOG("HRD %u -> %u bits (%u bit/s, %.2f i/s)\n", hrd->buffer_size, size, rate, (double)num / den);
    hrd->buffer_size = size;
    hrd->initial_buffer_fullness = size / 4 * 3;
}

VAStatus vaCreateConfig(VADisplay dpy, VAProfile profile, VAEntrypoint ep, VAConfigAttrib *attr, int n,
                        VAConfigID *id)
{
    static create_config_fn next;
    if (!next && !(next = (create_config_fn)next_sym("vaCreateConfig")))
        return VA_STATUS_ERROR_UNKNOWN;
    if ((ep != VAEntrypointEncSlice && ep != VAEntrypointEncSliceLP) || n <= 0 || !attr)
        return next(dpy, profile, ep, attr, n, id);

    VAConfigAttrib copy[n];
    memcpy(copy, attr, sizeof(copy));
    for (int i = 0; i < n; i++)
        if (copy[i].type == VAConfigAttribRateControl && copy[i].value != VA_RC_CBR) {
            LOG("contrôle de débit 0x%x -> CBR\n", copy[i].value);
            copy[i].value = VA_RC_CBR;
        }
    return next(dpy, profile, ep, copy, n, id);
}

VAStatus vaCreateBuffer(VADisplay dpy, VAContextID ctx, VABufferType type, unsigned int size, unsigned int num,
                        void *data, VABufferID *id)
{
    static create_buffer_fn next;
    if (!next && !(next = (create_buffer_fn)next_sym("vaCreateBuffer")))
        return VA_STATUS_ERROR_UNKNOWN;
    if (type != VAEncMiscParameterBufferType || !data || size < sizeof(VAEncMiscParameterBuffer))
        return next(dpy, ctx, type, size, num, data, id);

    VAEncMiscParameterBuffer *misc = data;
    switch (misc->type) {
    case VAEncMiscParameterTypeRateControl:
        pthread_mutex_lock(&lock);
        bps = ((VAEncMiscParameterRateControl *)misc->data)->bits_per_second;
        pthread_mutex_unlock(&lock);
        return next(dpy, ctx, type, size, num, data, id);

    case VAEncMiscParameterTypeFrameRate: {
        /* 16 bits de poids faible : numérateur, de poids fort : dénominateur (0 = 1) */
        uint32_t fr = ((VAEncMiscParameterFrameRate *)misc->data)->framerate;
        pthread_mutex_lock(&lock);
        fps_num = fr & 0xffff;
        fps_den = fr >> 16 ? fr >> 16 : 1;
        VADisplay d = hrd_dpy;
        VABufferID b = hrd_buf;
        hrd_buf = VA_INVALID_ID;
        pthread_mutex_unlock(&lock);

        /* ffmpeg transmet HRD avant FrameRate : on corrige le tampon HRD déjà créé */
        static map_buffer_fn map;
        static unmap_buffer_fn unmap;
        if (!map) {
            map = (map_buffer_fn)next_sym("vaMapBuffer");
            unmap = (unmap_buffer_fn)next_sym("vaUnmapBuffer");
        }
        void *p;
        if (b != VA_INVALID_ID && map && unmap && map(d, b, &p) == VA_STATUS_SUCCESS) {
            VAEncMiscParameterBuffer *m = p;
            if (m->type == VAEncMiscParameterTypeHRD)
                patch_hrd((VAEncMiscParameterHRD *)m->data);
            unmap(d, b);
        }
        return next(dpy, ctx, type, size, num, data, id);
    }

    case VAEncMiscParameterTypeHRD: {
        unsigned char copy[size];
        memcpy(copy, data, size);
        patch_hrd((VAEncMiscParameterHRD *)((VAEncMiscParameterBuffer *)copy)->data);
        VAStatus s = next(dpy, ctx, type, size, num, copy, id);
        if (s == VA_STATUS_SUCCESS) {
            pthread_mutex_lock(&lock);
            hrd_dpy = dpy;
            hrd_buf = *id;
            pthread_mutex_unlock(&lock);
        }
        return s;
    }

    case VAEncMiscParameterTypeQualityLevel: {
        const char *e = getenv("STEAMD_VA_QUALITY");
        if (!e || !*e)
            return next(dpy, ctx, type, size, num, data, id);
        unsigned char copy[size];
        memcpy(copy, data, size);
        VAEncMiscParameterBufferQualityLevel *q =
            (VAEncMiscParameterBufferQualityLevel *)((VAEncMiscParameterBuffer *)copy)->data;
        LOG("niveau de qualité %u -> %s\n", q->quality_level, e);
        q->quality_level = (uint32_t)atoi(e);
        return next(dpy, ctx, type, size, num, copy, id);
    }

    default:
        return next(dpy, ctx, type, size, num, data, id);
    }
}
