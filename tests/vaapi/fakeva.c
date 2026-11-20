/* Fausse libva : affiche ce que reçoit le « pilote » (mode de débit, tampon HRD) */
#include <stdio.h>
#include <string.h>
#include <va/va.h>

static unsigned char store[16][256];
static int nbuf;

VAStatus vaCreateConfig(VADisplay d, VAProfile p, VAEntrypoint e, VAConfigAttrib *a, int n, VAConfigID *id)
{
    (void)d; (void)p; (void)e;
    for (int i = 0; i < n; i++)
        if (a[i].type == VAConfigAttribRateControl)
            printf("pilote RC=0x%x\n", a[i].value);
    *id = 1;
    return VA_STATUS_SUCCESS;
}

VAStatus vaCreateBuffer(VADisplay d, VAContextID c, VABufferType t, unsigned s, unsigned n, void *data, VABufferID *id)
{
    (void)d; (void)c; (void)t; (void)n;
    memcpy(store[nbuf], data, s);
    *id = nbuf++;
    return VA_STATUS_SUCCESS;
}

VAStatus vaMapBuffer(VADisplay d, VABufferID b, void **p) { (void)d; *p = store[b]; return VA_STATUS_SUCCESS; }
VAStatus vaUnmapBuffer(VADisplay d, VABufferID b) { (void)d; (void)b; return VA_STATUS_SUCCESS; }

void fake_dump_hrd(VABufferID b)
{
    VAEncMiscParameterHRD *h = (void *)((VAEncMiscParameterBuffer *)store[b])->data;
    printf("pilote HRD=%u plein=%u\n", h->buffer_size, h->initial_buffer_fullness);
}
