/* « Encodeur » façon ffmpeg : VBR demandé, puis RateControl, HRD (1 s) et
 * FrameRate à chaque image clé. Lié à libva et chargé en RTLD_LOCAL, comme dans Steam. */
#include <stdio.h>
#include <string.h>
#include <va/va.h>

void fake_dump_hrd(VABufferID);

static VABufferID misc(VAEncMiscParameterType t, void *p, size_t n)
{
    unsigned char b[256] = {0};
    ((VAEncMiscParameterBuffer *)b)->type = t;
    memcpy(((VAEncMiscParameterBuffer *)b)->data, p, n);
    VABufferID id;
    vaCreateBuffer(0, 0, VAEncMiscParameterBufferType, sizeof(VAEncMiscParameterBuffer) + n, 1, b, &id);
    return id;
}

int run(void)
{
    VAConfigAttrib a = {VAConfigAttribRateControl, VA_RC_VBR};
    VAConfigID c;
    vaCreateConfig(0, VAProfileHEVCMain, VAEntrypointEncSlice, &a, 1, &c);
    printf("appli RC=0x%x\n", a.value);
    for (int idr = 0; idr < 2; idr++) {
        VAEncMiscParameterRateControl rc = {.bits_per_second = 18000000};
        misc(VAEncMiscParameterTypeRateControl, &rc, sizeof rc);
        VAEncMiscParameterHRD h = {.buffer_size = 18000000, .initial_buffer_fullness = 13500000};
        VABufferID hb = misc(VAEncMiscParameterTypeHRD, &h, sizeof h);
        VAEncMiscParameterFrameRate fr = {.framerate = 90 | (1 << 16)};
        misc(VAEncMiscParameterTypeFrameRate, &fr, sizeof fr);
        fake_dump_hrd(hb);
    }
    return 0;
}
