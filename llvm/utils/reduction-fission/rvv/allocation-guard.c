#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>

struct allocation { unsigned char *ptr, *mapping; size_t size, padded, length; };
static struct allocation allocations[64];
static size_t live, peak, calls, frees;
static void fail(const char *message) { fprintf(stderr,"allocation guard: %s\n",message); abort(); }
static void *guard_allocate(size_t size, size_t alignment) {
  if (!size) fail("unexpected zero-sized scratch");
  size_t page=(size_t)sysconf(_SC_PAGESIZE);
  if(size>SIZE_MAX-4*page) return NULL;
  size_t padded=(size+alignment-1)&~(alignment-1);
  size_t payload=(padded+16+page-1)&~(page-1);
  size_t length=payload+2*page;
  unsigned char *mapping=mmap(NULL,length,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
  if(mapping==MAP_FAILED) return NULL;
  if(mprotect(mapping+page,payload,PROT_READ|PROT_WRITE)) fail("mprotect failed");
  unsigned char *ptr=mapping+page+payload-padded;
  memset(ptr-16,0x5a,16);
  memset(ptr,0xcc,size);
  memset(ptr+size,0xa5,padded-size);
  for(unsigned i=0;i<64;++i) if(!allocations[i].ptr) {
    allocations[i]=(struct allocation){ptr,mapping,size,padded,length};
    ++calls; if(++live>peak) peak=live; return ptr;
  }
  fail("too many live buffers"); return NULL;
}
void *__wrap_malloc(size_t size) { return guard_allocate(size,16); }
void *fission_guarded_input(size_t size) { return size ? guard_allocate(size,1) : NULL; }
void __wrap_free(void *memory) {
  if(!memory) return;
  for(unsigned i=0;i<64;++i) if(allocations[i].ptr==memory) {
    struct allocation a=allocations[i];
    for(unsigned j=0;j<16;++j) if(a.ptr[-16+(int)j]!=0x5a) fail("write before buffer");
    for(size_t j=a.size;j<a.padded;++j) if(a.ptr[j]!=0xa5) fail("write after buffer");
    if(munmap(a.mapping,a.length)) fail("munmap failed");
    allocations[i].ptr=NULL; --live; ++frees; return;
  }
  fail("invalid or duplicate free");
}
void fission_check_allocations(void) {
  if(live || calls!=frees) fail("scratch lifetime leak");
  printf("guarded allocations=%zu frees=%zu peak_live=%zu\n",calls,frees,peak);
}
