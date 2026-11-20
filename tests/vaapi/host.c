/* Charge l'encodeur en RTLD_LOCAL : libva hors de portée de dlsym(RTLD_NEXT) */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    void *h = dlopen(argc > 1 ? argv[1] : "./libenc.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        puts(dlerror());
        return 1;
    }
    int (*run)(void) = (int (*)(void))dlsym(h, "run");
    return run();
}
