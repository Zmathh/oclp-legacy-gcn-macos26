#include <dlfcn.h>
#include <stdio.h>
int main(void){
    void *h = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    printf("IOSurface : %s\n", h ? "chargee" : dlerror());
    if (!h) return 1;
    const char *n[] = {"kIOSurfaceCreationProperties","kIOSurfaceAllocSize",
                       "IOSurfaceCopyValue","kIOSurfaceIsGlobal","kIOSurfaceWidth",
                       "IOSurfaceCopyAllValues",0};
    for (int i=0;n[i];i++){ void *p = dlsym(h,n[i]);
        printf("  %-32s %s\n", n[i], p ? "present" : "ABSENT"); }
    return 0;
}
