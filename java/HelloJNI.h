#include <jni.h>
#ifndef _Included_HelloJNI
#define _Included_HelloJNI
#ifdef __cplusplus
extern "C" {
#endif
JNIEXPORT void JNICALL Java_HelloJNI_sayHello(JNIEnv *, jobject);
#ifdef __cplusplus
}
#endif
#endif
