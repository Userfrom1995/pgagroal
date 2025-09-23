/*
 * Various things to allow source files from postgresql code to be
 * used in pgagroal.
 */

/* from c.h */

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>

#include <endian.h>
#ifndef htobe32
#ifdef __BYTE_ORDER__
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define htobe32(x) __builtin_bswap32(x)
#else
#define htobe32(x) (x)
#endif
#endif
#endif

#ifdef CASSERT
#define USE_ASSERT_CHECKING
#endif

#define int8 int8_t
#define uint8 uint8_t
#define uint16 uint16_t
#define uint32 uint32_t
#define uint64 uint64_t
#define Size size_t

#define lengthof(array) (sizeof (array) / sizeof ((array)[0]))
#define pg_hton32(x) htobe32(x)

#define HIGHBIT					(0x80)
#define IS_HIGHBIT_SET(ch)		((unsigned char)(ch) & HIGHBIT)

#define UINT64CONST(x) (x##ULL)

/* ignore gettext */
#define _(x) (x)

typedef unsigned int Oid;

#define MaxAllocSize    ((Size) 0x3fffffff)

#define pg_nodiscard
#define pg_noreturn
#ifdef __GNUC__
#define pg_restrict __restrict
#else
#define pg_restrict
#endif

/* define this to use non-server code paths */
#define FRONTEND

/* Memory allocation macros for frontend */
#define palloc(size) malloc(size)
#define pfree(ptr) free(ptr)
#define pstrdup(str) strdup(str)

/* Assert macro */
#ifdef USE_ASSERT_CHECKING
#include <assert.h>
#define Assert(condition) assert(condition)
#else
#define Assert(condition) ((void)0)
#endif
