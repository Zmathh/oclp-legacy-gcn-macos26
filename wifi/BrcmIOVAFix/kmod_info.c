// Ce que Xcode genere pour un kext (MODULE_NAME / MODULE_START / MODULE_STOP).
#include <mach/mach_types.h>

extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);
__private_extern__ kern_return_t BrcmIOVAFix_kern_start(kmod_info_t *, void *);
__private_extern__ kern_return_t BrcmIOVAFix_kern_stop(kmod_info_t *, void *);

__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(com.zmathh.BrcmIOVAFix, "1.0.0", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = BrcmIOVAFix_kern_start;
__private_extern__ kmod_stop_func_t *_antimain = BrcmIOVAFix_kern_stop;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
