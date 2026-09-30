#import <Foundation/Foundation.h>
#include <dlfcn.h>
int main(void){@autoreleasepool{
    void *h=dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface",RTLD_NOW);
    if(!h){printf("%s\n",dlerror());return 1;}
    const char *n[]={"kIOSurfaceCreationProperties","kIOSurfaceAllocSize",0};
    for(int i=0;n[i];i++){
        CFStringRef *pp=(CFStringRef*)dlsym(h,n[i]);
        if(!pp){printf("  %-30s ABSENT\n",n[i]);continue;}
        CFStringRef v=*pp;
        printf("  %-30s -> %s\n", n[i], v?[(__bridge NSString*)v UTF8String]:"(nul)");
    }
    return 0;}}
