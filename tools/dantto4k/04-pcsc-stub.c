/* PCSC stubs for a remux-only (--frontend-descrambled) static build of dantto4k.
 *
 * なぜ必要か:
 *   Alpine の pcsc-lite-dev は共有ライブラリしか配布しておらず libpcsclite.a が無い。
 *   一方 dantto4k は smartCard.cpp / casProxyClient.cpp を常にビルドするため、
 *   静的リンクすると PCSC のシンボルが未解決になる。
 *
 * なぜ安全か:
 *   --frontend-descrambled では dantto4k.cpp:242 の `if (!args.frontendDescrambled)`
 *   に入らず AcasHandler が生成されないので、これらは一度も呼ばれない。
 *   STB では b61dec が ACAS 復号を済ませているのでこのモードしか使わない。
 *   万一呼ばれた場合は黙って成功を装わず SCARD_F_INTERNAL_ERROR を返す。
 *
 * 使い方:
 *   gcc -c 04-pcsc-stub.c -o pcsc-stub.o
 *   g++ build/*.o pcsc-stub.o -static -o build/dantto4k-static \
 *       $(pkg-config --libs --static tsduck) -lz -latomic -pthread
 */
#include <stdint.h>

#define SCARD_FAIL 0x80100001L /* SCARD_F_INTERNAL_ERROR */

long SCardEstablishContext(unsigned long a, const void *b, const void *c, long *d)
{ (void)a; (void)b; (void)c; (void)d; return SCARD_FAIL; }

long SCardReleaseContext(long a)
{ (void)a; return SCARD_FAIL; }

long SCardListReaders(long a, const char *b, char *c, unsigned long *d)
{ (void)a; (void)b; (void)c; (void)d; return SCARD_FAIL; }

long SCardConnect(long a, const char *b, unsigned long c, unsigned long d, long *e, unsigned long *f)
{ (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; return SCARD_FAIL; }

long SCardReconnect(long a, unsigned long b, unsigned long c, unsigned long d, unsigned long *e)
{ (void)a; (void)b; (void)c; (void)d; (void)e; return SCARD_FAIL; }

long SCardDisconnect(long a, unsigned long b)
{ (void)a; (void)b; return SCARD_FAIL; }

long SCardBeginTransaction(long a)
{ (void)a; return SCARD_FAIL; }

long SCardEndTransaction(long a, unsigned long b)
{ (void)a; (void)b; return SCARD_FAIL; }

long SCardTransmit(long a, const void *b, const unsigned char *c, unsigned long d,
                   void *e, unsigned char *f, unsigned long *g)
{ (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; return SCARD_FAIL; }

long SCardGetAttrib(long a, unsigned long b, unsigned char *c, unsigned long *d)
{ (void)a; (void)b; (void)c; (void)d; return SCARD_FAIL; }

long SCardFreeMemory(long a, const void *b)
{ (void)a; (void)b; return SCARD_FAIL; }

long SCardStatus(long a, char *b, unsigned long *c, unsigned long *d,
                 unsigned long *e, unsigned char *f, unsigned long *g)
{ (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; return SCARD_FAIL; }

/* SCARD_IO_REQUEST { unsigned long dwProtocol; unsigned long cbPciLength; } */
struct ts_scard_io_request { unsigned long dwProtocol; unsigned long cbPciLength; };
const struct ts_scard_io_request g_rgSCardT0Pci  = { 1, 8 };
const struct ts_scard_io_request g_rgSCardT1Pci  = { 2, 8 };
const struct ts_scard_io_request g_rgSCardRawPci = { 4, 8 };
