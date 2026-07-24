#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Increments backend reference count and initializes llama backend on first use.
void noema_llama_backend_addref(void);

// Decrements backend reference count and frees llama backend when it reaches zero.
void noema_llama_backend_release(void);

// Returns current backend reference count.
int noema_llama_backend_refcount(void);

#ifdef __cplusplus
}
#endif
