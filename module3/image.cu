#include <stdio.h>
#include <ctype.h>
#include "getopt.h"
#include <stdint.h>


#define ARRAY_SIZE 2560  // Value chosen to match # cores in a GTX 1080 GPU
#define ARRAY_SIZE_IN_BYTES (sizeof(unsigned int) * (ARRAY_SIZE))

#define BLOCK_SIZE 32 // Default value. Original example was 16.

/* TODO: Define more realistic limits. For now,
 * num_threads>ARRAY_SIZE/num_blocks is good enough to make these
 * limits redundant */
#define MAX_BLOCKS ARRAY_SIZE
#define MAX_THREADS ARRAY_SIZE

/* Declare  statically two arrays of ARRAY_SIZE each */
unsigned int cpu_block[ARRAY_SIZE];
unsigned int cpu_thread[ARRAY_SIZE];
unsigned int cpu_data[ARRAY_SIZE];

/* Image Generation Configuration
 *  We'll use a simple RGB color scheme
 *  This can be extended to other schemes (ie: sRGB, IAB) if needed later
 */
#if 0 // 10-bit color space -- good in theory, but harder to display in a useful format
#define TWO_BYTE_COLOR
#define MAX_COLOR 1023
#define R_SHIFT 0
#define G_SHIFT 10
#define B_SHIFT 20
#define R_MASK 0x000003FF
#define G_MASK 0x000FFC00
#define B_MASK 0x3FF00000
#define S_MASK 0xC0000000 // reserved (ie: alpha channel)
#else
// Note: We still reserve 10-bits per channel, but only use 8 when outputting
#define MAX_COLOR 255
#define R_SHIFT 0
#define G_SHIFT 10
#define B_SHIFT 20
#define R_MASK 0x000003FF
#define G_MASK 0x000FFC00
#define B_MASK 0x3FF00000
#define S_MASK 0xC0000000 // reserved (ie: alpha channel)

#endif

#define GET_R(data) (data & R_MASK)
#define GET_G(data) ((data & G_MASK) >> G_SHIFT)
#define GET_B(data) ((data & B_MASK) >> B_SHIFT)

#define GET_Rxy(x,y) (GET_R(cpu_data[x*width+y]))
#define GET_Gxy(x,y) (GET_G(cpu_data[x*width+y]))
#define GET_Bxy(x,y) (GET_B(cpu_data[x*width+y]))


// Write cpu_data as a PPM-formatted image (http://netpbm.sourceforge.net/doc/ppm.html)
void write_image(unsigned int width, unsigned int height)
{
  char fn[64];
  FILE *f;
  #ifdef TWO_BYTE_COLOR
  uint16_t c[3];
  #else
  uint8_t c[3];
  #endif

  sprintf(fn, "%d-%d.ppm", width, height);
  f = fopen(fn, "wb");
  fprintf(f, "P6\n%i %i %i\n", width, height, MAX_COLOR);
  for (int y=0; y<height; y++) {
    for (int x=0; x<width; x++) {
      c[0] = GET_Rxy(x,y);
      c[1] = GET_Gxy(x,y);
      c[2] = GET_Bxy(x,y);
#ifdef TWO_BYTE_COLOR
      fwrite(c, 2, 3, f);
#else
      fwrite(c, 1, 3, f);
#endif
      //printf("%d,%d = %d %d %d\n", x,y,c[0],c[1],c[2]);
    }
  }
  fclose(f);
}

__global__
void what_is_my_id(unsigned int * block, unsigned int * thread, unsigned int * data)
{
  // blockNum * thradsPerBlock + threadNum
  const unsigned int thread_idx = (blockIdx.x * blockDim.x) + threadIdx.x;
  block[thread_idx] = blockIdx.x;
  thread[thread_idx] = threadIdx.x;

  data[thread_idx] =
    (threadIdx.x & R_MASK) | // threadIdx lower-bits sets the red color
    ((blockIdx.x*10<<G_SHIFT) & G_MASK) | // blockIdx lower-bits sets the green color
    ((thread_idx<<B_SHIFT) & B_MASK); // thread_idx lower-bits itself will be the blue value
	
}

void main_sub0(unsigned int num_threads, unsigned int num_blocks, int verbose)
{

	/* Declare pointers for GPU based params */
	unsigned int *gpu_block;
	unsigned int *gpu_thread;
	unsigned int *gpu_data;

	cudaMalloc((void **)&gpu_block, ARRAY_SIZE_IN_BYTES);
	cudaMalloc((void **)&gpu_thread, ARRAY_SIZE_IN_BYTES);
	cudaMalloc((void **)&gpu_data, ARRAY_SIZE_IN_BYTES);

	cudaMemcpy( gpu_block, cpu_block, ARRAY_SIZE_IN_BYTES, cudaMemcpyHostToDevice );
	cudaMemcpy( gpu_thread, cpu_thread, ARRAY_SIZE_IN_BYTES, cudaMemcpyHostToDevice );
	cudaMemcpy( gpu_data, gpu_data, ARRAY_SIZE_IN_BYTES, cudaMemcpyHostToDevice );

	/* Execute our kernel */
	what_is_my_id<<<num_blocks, num_threads>>>(gpu_block, gpu_thread, gpu_data);

	/* Free the arrays on the GPU as now we're done with them */
	cudaMemcpy( cpu_block, gpu_block, ARRAY_SIZE_IN_BYTES, cudaMemcpyDeviceToHost );
	cudaMemcpy( cpu_thread, gpu_thread, ARRAY_SIZE_IN_BYTES, cudaMemcpyDeviceToHost );
	cudaMemcpy( cpu_data, gpu_data, ARRAY_SIZE_IN_BYTES, cudaMemcpyDeviceToHost );
	cudaFree(gpu_block);
	cudaFree(gpu_thread);
	cudaFree(gpu_data);

	/* Iterate through the arrays and output */
	if (verbose) {
	  for(unsigned int i = 0; i < ARRAY_SIZE; i++)
	  {
	    printf("Thread: %2u - Block: %2u - Data: %08x - %03u %03u %03u\n",
		   cpu_thread[i],cpu_block[i],cpu_data[i],
		   GET_R(cpu_data[i]), GET_G(cpu_data[i]), GET_B(cpu_data[i]));
	  }
	}

	write_image(num_blocks, num_threads);
}

int main(int argc, char* argv[])
{
  unsigned int blk_size = BLOCK_SIZE;
  unsigned int num_threads = ARRAY_SIZE/blk_size;
  int c;
  int verbose = 0;
  
  while((c = getopt(argc, argv, "hvb:t:")) != -1) {
    switch(c) {
    case 'b':
      blk_size = atoi(optarg);
      break;
    case 't':
      num_threads = atoi(optarg);
      break;
    case 'v':
      verbose = 1;
      break;
    case 'h':
      printf("Usage: \n");
      printf("\t-h     Show this message\n");
      printf("\t-v     Enable verbose output mode.\n");
      printf("\t-b 32  Specify number of blocks to use (ie: 32 in this example). Default is %d\n", BLOCK_SIZE);
      printf("\t-t 32  Specify number of threads per block to use (ie: 32 in this example). Default is %d\n", ARRAY_SIZE/BLOCK_SIZE);
      return -1;
    default:
      printf("ERROR: Option %s is not supported, type h for usage info.\n", c);
      return -1;
    }
  }
  if (blk_size > MAX_BLOCKS)
  {
    printf("ERROR: blk_size (%d specified) must be <= max BLOCK_SIZE of %d\n", blk_size, BLOCK_SIZE);
    return -1;
  } else {
    printf("blk_size set to %d\n", blk_size);
  }
  if (num_threads > MAX_THREADS || num_threads > ARRAY_SIZE/blk_size)
  {
    printf("ERROR: num_threads (%d) cannot exceed %d, or %d/blk_size=%d\n", num_threads, MAX_THREADS, ARRAY_SIZE, ARRAY_SIZE/blk_size);
    return -1;
  } else {
    printf("num_threads set to %d\n", num_threads);
  }

  
  main_sub0(num_threads, blk_size, verbose);
	
  return EXIT_SUCCESS;
}
