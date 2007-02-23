#ifndef _BASE_
#define _BASE_

#ifdef WIN32
  typedef int bool;
  enum
  {
      false,
      true
  };

  typedef unsigned char u_int8_t; 
  typedef unsigned short uint16_t;
  typedef unsigned int uint32_t;
  typedef unsigned long long uint64_t;

  #define ETIMEDOUT 10060

  #include <winsock.h>

  #define getpid GetCurrentProcessId
  #define setlinebuf(a)
  #define _snprintf snprintf

  /* thread defines */
  #define THREAD_PTR HANDLE
  bool startThread(THREAD_PTR *handle, void* (*target)(void*), void *arg);
  bool joinThread(THREAD_PTR *handle, void **exitVal);

  /* lock defines */
  #define LOCK_PTR CRITICAL_SECTION

#else
  #include <stdbool.h>
  #include <stdint.h>
  #include <unistd.h>
  #include <pthread.h>

  /* thread defines */
  #define THREAD_PTR pthread_t
  #define startThread(a, b, c) (pthread_create((a), NULL, (b), (c)) == 0)
  #define joinThread(a,b) (pthread_join((a), (b)) == 0)

  /* lock defines */
  #define LOCK_PTR pthread_mutex_t
  #define InitializeCriticalSection(a) pthread_mutex_init((a), NULL)
  #define EnterCriticalSection pthread_mutex_lock
  #define LeaveCriticalSection pthread_mutex_unlock

#endif

uint64_t microsSinceX();

#endif
