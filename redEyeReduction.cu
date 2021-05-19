#include <stdio.h>
#include <cuda.h>
#include "redEyeReduction.h"
#include "cuda_runtime.h"

#define PROFILE 1
#define BLOCK_SIZE 256
dim3 blockSize(32, 8, 1);

namespace redEyeReduction {
	void splitChannels(Mat im, unsigned char *red, unsigned char *green, unsigned char *blue) {
		size_t numPixels = im.rows*im.cols;
		unsigned char *imgPtr = new unsigned char[numPixels * im.channels()];
		unsigned char *cvPtr = im.ptr<unsigned char>(0);         // For Efficient Pixel Access
		for (size_t i = 0; i < numPixels * im.channels(); ++i) {
			imgPtr[i] = cvPtr[i];
		}
		for (size_t i = 0; i < numPixels; ++i) {
			blue[i] = imgPtr[3 * i + 0];
			green[i] = imgPtr[3 * i + 1];
			red[i] = imgPtr[3 * i + 2];
		}
		delete[] imgPtr;
	}
	
	__global__ void naive_normalized_cross_correlation(float* dev_response, unsigned char* dev_original, unsigned char* dev_template,
		int rows, int cols, int template_half_height, int template_height, int template_half_width, int template_width,
		int template_size, float template_mean)
	{
	  int2 image_index_2d = make_int2( ( blockIdx.x * blockDim.x ) + threadIdx.x, ( blockIdx.y * blockDim.y ) + threadIdx.y );
	  int  image_index_1d = (cols * image_index_2d.y) + image_index_2d.x;

	  if (image_index_2d.x < cols && image_index_2d.y < rows)
	  {
		float image_sum = 0.0f;

		for ( int y = -template_half_height; y <= template_half_height; y++ ) {
		  for ( int x = -template_half_width; x <= template_half_width; x++ )  {
			int2 image_offset_index_2d         = make_int2( image_index_2d.x + x, image_index_2d.y + y );
			int2 image_offset_index_2d_clamped = make_int2(min(cols - 1, max(0, image_offset_index_2d.x)), min(rows - 1, max(0, image_offset_index_2d.y)));
			int  image_offset_index_1d_clamped = (cols * image_offset_index_2d_clamped.y) + image_offset_index_2d_clamped.x;

			unsigned char image_offset_value = dev_original[ image_offset_index_1d_clamped ];

			image_sum += (float)image_offset_value;
		  }
		}

		float image_mean = image_sum / (float)template_size;

		float sum_of_image_template_diff_products = 0.0f;
		float sum_of_squared_image_diffs          = 0.0f;
		float sum_of_squared_template_diffs       = 0.0f;

		for ( int y = -template_half_height; y <= template_half_height; y++ ) {
		  for ( int x = -template_half_width; x <= template_half_width; x++ )  {
			int2 image_offset_index_2d         = make_int2( image_index_2d.x + x, image_index_2d.y + y );
			int2 image_offset_index_2d_clamped = make_int2(min(cols - 1, max(0, image_offset_index_2d.x)), min(rows - 1, max(0, image_offset_index_2d.y)));
			int  image_offset_index_1d_clamped = (cols * image_offset_index_2d_clamped.y) + image_offset_index_2d_clamped.x;

			unsigned char image_offset_value = dev_original[ image_offset_index_1d_clamped ];
			float         image_diff         = (float)image_offset_value - image_mean;

			int2 template_index_2d = make_int2( x + template_half_width, y + template_half_height );
			int  template_index_1d = (template_width * template_index_2d.y) + template_index_2d.x;

			unsigned char template_value = dev_template[ template_index_1d ];
			float         template_diff  = template_value - template_mean;

			float image_template_diff_product = image_offset_value   * template_diff;
			float squared_image_diff          = image_diff           * image_diff;
			float squared_template_diff       = template_diff        * template_diff;

			sum_of_image_template_diff_products += image_template_diff_product;
			sum_of_squared_image_diffs          += squared_image_diff;
			sum_of_squared_template_diffs       += squared_template_diff;
		  }
		}

		float result_value = 0.0f;

		if ( sum_of_squared_image_diffs != 0 && sum_of_squared_template_diffs != 0 ) {
		  result_value = sum_of_image_template_diff_products / sqrt( sum_of_squared_image_diffs * sum_of_squared_template_diffs );
		}
		dev_response[ image_index_1d ] = result_value;
	  }
	}

	__global__ void create_normalized_matrix(float *red, float *green, float *blue, float *combined, size_t rows, size_t cols) {
		int  ny = rows;
		int  nx = cols;
		int2 image_index_2d = make_int2((blockIdx.x * blockDim.x) + threadIdx.x, (blockIdx.y * blockDim.y) + threadIdx.y);
		int  image_index_1d = (nx * image_index_2d.y) + image_index_2d.x;

		if (image_index_2d.x < nx && image_index_2d.y < ny) {
			combined[image_index_1d] = red[image_index_1d] * green[image_index_1d] * blue[image_index_1d];
		}
	}

	__global__ void mean_shift(float* val, float constant, size_t rows, size_t cols) {
		int  ny = rows;
		int  nx = cols;
		int2 image_index_2d = make_int2((blockIdx.x * blockDim.x) + threadIdx.x, (blockIdx.y * blockDim.y) + threadIdx.y);
		int  image_index_1d = (nx * image_index_2d.y) + image_index_2d.x;

		if (image_index_2d.x < nx && image_index_2d.y < ny) {
			val[image_index_1d] = val[image_index_1d]-constant;
		}
	}

	__global__ void compute_histogram(unsigned int* dev_inputVals, unsigned int* dev_histogram, unsigned int pass, size_t numElems) {
			unsigned idx = threadIdx.x + blockIdx.x * blockDim.x;
			if (idx >= numElems) {
				return;
			}

			unsigned int bit = (dev_inputVals[idx] & (1u << pass)) >> pass;
			atomicAdd(&dev_histogram[bit], 1);
		}

	__global__ void scan_element(unsigned int* dev_inputVals, unsigned int* dev_scaned, unsigned int base, unsigned int pass,
		size_t numElems, unsigned int threadSize) {
			unsigned int idx = threadIdx.x + base * threadSize;
			if (idx >= numElems) {
				return;
			}

			unsigned int bit = (dev_inputVals[idx] & (1u << pass)) >> pass;
			dev_scaned[idx] = bit;
			__syncthreads();

			int spot, val;
			for (unsigned int s = threadSize >> 1; s > 0; s >>= 1) {
				spot = idx - s;
				if (spot >= 0 && spot >= base * threadSize) {
					val = dev_scaned[spot];
				}
				__syncthreads();
				if (spot >= 0 && spot >= base * threadSize) {
					dev_scaned[idx] += val;
				}
				__syncthreads();
			}

			if (base > 0) {
				dev_scaned[idx] += dev_scaned[base * threadSize - 1];
			}
		}

	__global__ void move_element(unsigned int* dev_inputVals, unsigned int* dev_inputPos, unsigned int* dev_outputVals, unsigned int* dev_outputPos,
		unsigned int* dev_histogram, unsigned int* dev_scaned, unsigned int pass, unsigned int numElems) {
			unsigned int idx = threadIdx.x + blockIdx.x * blockDim.x;
			if (idx >= numElems) {
				return;
			}

			unsigned int bit = (dev_inputVals[idx] & (1u << pass)) >> pass;
			unsigned int offset;
			if (bit) {
				offset = dev_histogram[0];
				if (idx > 0) {
					offset += dev_scaned[idx - 1];
				}
			}
			else {
				offset = idx - dev_scaned[idx];
			}
			dev_outputVals[offset] = dev_inputVals[idx];
			dev_outputPos[offset] = dev_inputPos[idx];
		}

	void sort(unsigned int* dev_inputVals, unsigned int* dev_inputPos, unsigned int* dev_outputVals, unsigned int* dev_outputPos,
		size_t numElems)
	{
		dim3 gridSize(ceil((float)(numElems) / BLOCK_SIZE) + 1);
		dim3 blockSize(1024);

		unsigned int* dev_histogram;
		cudaMalloc((void**)&dev_histogram, 2 * sizeof(unsigned int));
		unsigned int* dev_scaned;
		cudaMalloc((void**)&dev_scaned, numElems * sizeof(unsigned int));

		for (unsigned int pass = 0; pass < 8 * sizeof(unsigned int); ++pass) {
			cudaMemset(dev_histogram, 0, 2 * sizeof(unsigned int));
			cudaMemset(dev_scaned, 0, numElems * sizeof(unsigned int));
			cudaMemset(dev_outputVals, 0, numElems * sizeof(unsigned int));
			cudaMemset(dev_outputPos, 0, numElems * sizeof(unsigned int));

			#if PROFILE
				GpuTimer timer;
				timer.Start();
			#endif
			compute_histogram << <gridSize, BLOCK_SIZE >> >(dev_inputVals, dev_histogram, pass, numElems);
			cudaDeviceSynchronize();

			for (unsigned int base = 0; base < gridSize.x; base++) {
				scan_element << <dim3(1), 1024 >> >(dev_inputVals, dev_scaned, base, pass, numElems, blockSize.x);
				cudaDeviceSynchronize();
			}

			move_element << <gridSize, BLOCK_SIZE >> >(dev_inputVals, dev_inputPos, dev_outputVals, dev_outputPos, dev_histogram, dev_scaned, pass, numElems);
			cudaDeviceSynchronize();
			#if PROFILE
				timer.Stop();
				printf("sort: %f msecs.\n", timer.Elapsed());
			#endif

			cudaMemcpy(dev_inputVals, dev_outputVals, numElems * sizeof(unsigned int), cudaMemcpyDeviceToDevice);
			cudaMemcpy(dev_inputPos, dev_outputPos, numElems * sizeof(unsigned int), cudaMemcpyDeviceToDevice);
			cudaDeviceSynchronize();
		}

		cudaFree(dev_histogram);
		cudaFree(dev_scaned);
	}

	__global__ void allocatePos(unsigned int *val, size_t size) {
		unsigned int idx = threadIdx.x + blockIdx.x * blockDim.x;
		if (idx >= size) {
			return;
		}
		val[idx] = idx;
	}

	__global__ void remove_redness_from_coordinates(unsigned int*  dev_coordinates, unsigned char* dev_blue, unsigned char* dev_green, unsigned char* dev_red_output, 
		int num_coordinates, int rows, int cols, int template_half_height, int template_half_width)
	{
		int global_index_1d = (blockIdx.x * blockDim.x) + threadIdx.x;

		int imgSize = cols * rows;

		if (global_index_1d < num_coordinates) {
			unsigned int image_index_1d = dev_coordinates[imgSize - global_index_1d - 1];
			ushort2 image_index_2d = make_ushort2(image_index_1d % cols, image_index_1d / cols);

			for (int y = image_index_2d.y - template_half_height; y <= image_index_2d.y + template_half_height; y++)
			{
				for (int x = image_index_2d.x - template_half_width; x <= image_index_2d.x + template_half_width; x++)
				{
					int2 image_offset_index_2d_clamped = make_int2(min(cols - 1, max(0, x)), min(rows - 1, max(0, y)));
					int  idx = (cols * image_offset_index_2d_clamped.y) + image_offset_index_2d_clamped.x;

					unsigned int gb_average = (dev_green[idx] + dev_blue[idx]) / 2;
					dev_red_output[idx] = (unsigned char)gb_average;
				}
			}

		}
	}
	__global__ void reduce_minmax_kernel(float* const dev_in, float* dev_out, size_t size, int minmax) {
		extern __shared__ float shared[];

		int mid = threadIdx.x + blockDim.x * blockIdx.x;
		int tid = threadIdx.x;

		if (mid < size) {
			shared[tid] = dev_in[mid];
		}
		else {
			if (minmax == 0)
				shared[tid] = FLT_MAX;
			else
				shared[tid] = -FLT_MAX;
		}

		__syncthreads();

		if (mid >= size) {
			if (tid == 0) {
				if (minmax == 0)
					dev_out[blockIdx.x] = FLT_MAX;
				else
					dev_out[blockIdx.x] = -FLT_MAX;
			}
			return;
		}

		for (unsigned int s = blockDim.x / 2; s > 0; s /= 2) {
			if (tid < s) {
				if (minmax == 0) {
					shared[tid] = min(shared[tid], shared[tid + s]);
				}
				else {
					shared[tid] = max(shared[tid], shared[tid + s]);
				}
			}

			__syncthreads();
		}

		if (tid == 0) {
			dev_out[blockIdx.x] = shared[0];
		}
	}

	float reduce_minmax(float* d_in, size_t size, int minmax) {
		size_t curr_size = size;
		float* dev_data;

		cudaMalloc(&dev_data, sizeof(float)* size);
		cudaMemcpy(dev_data, d_in, sizeof(float)* size, cudaMemcpyDeviceToDevice);


		float* dev_temp;

		dim3 thread_dim(BLOCK_SIZE);
		const int shared_mem_size = sizeof(float)*BLOCK_SIZE;
		dim3 block_dim((int)ceil((float)size / (float)BLOCK_SIZE) + 1);
		int maxSize;
		#if PROFILE
			GpuTimer timer;
		#endif
		while (1) {
			maxSize = (int)ceil((float)curr_size / (float)BLOCK_SIZE) + 1;
			cudaMalloc(&dev_temp, sizeof(float)* maxSize);

			#if PROFILE
				timer.Start();
			#endif
			reduce_minmax_kernel << <block_dim, thread_dim, shared_mem_size >> >(dev_data, dev_temp, curr_size, minmax);
			#if PROFILE
				timer.Stop();
				printf("minMax: %f msecs.\n", timer.Elapsed());
			#endif
			cudaDeviceSynchronize();


			// move the current input to the output, and clear the last input if necessary
			cudaFree(dev_data);
			dev_data = dev_temp;

			if (curr_size <  BLOCK_SIZE)
				break;

			curr_size = maxSize;
		}

		// theoretically we should be 
		float result;
		cudaMemcpy(&result, dev_temp, sizeof(float), cudaMemcpyDeviceToHost);
		cudaFree(dev_temp);
		return result;
	}

	Mat gpuRER(Mat im, Mat eyeTemplate) {
		size_t rows = im.rows;
		size_t cols = im.cols;
		size_t numPixels = rows * cols;
		unsigned char *red = new  unsigned char[numPixels];
		unsigned char *green = new  unsigned char[numPixels];
		unsigned char *blue = new  unsigned char[numPixels];
		size_t rows_template = eyeTemplate.rows;
		size_t cols_template = eyeTemplate.cols;
		size_t numPixels_template = rows_template * cols_template;
		unsigned char *red_template = new  unsigned char[numPixels_template];
		unsigned char *green_template = new  unsigned char[numPixels_template];
		unsigned char *blue_template = new  unsigned char[numPixels_template];

		splitChannels(im, red, green, blue);
		splitChannels(eyeTemplate, red_template, green_template, blue_template);
		
		unsigned int r_sum = 0, g_sum = 0, b_sum = 0;
		float r_mean, g_mean, b_mean;
		for (int i = 0; i < numPixels_template; ++i)	{
			r_sum += red_template[i];
			g_sum += green_template[i];
			b_sum += blue_template[i];
		}
		r_mean = ((float)r_sum) / numPixels_template;
		g_mean = ((float)g_sum) / numPixels_template;
		b_mean = ((float)b_sum) / numPixels_template;

		unsigned char *dev_red, *dev_green, *dev_blue;
		unsigned char *dev_red_template, *dev_green_template, *dev_blue_template;
		float *dev_red_normalized, *dev_green_normalized, *dev_blue_normalized;
		float *dev_normalized;
		unsigned int *dev_input, *dev_normalized_sorted;
		unsigned int *dev_ipPosition, *dev_opPosition;
		cudaMalloc((void**)&dev_red, sizeof(unsigned char)*numPixels);
		cudaMalloc((void**)&dev_green, sizeof(unsigned char)*numPixels);
		cudaMalloc((void**)&dev_blue, sizeof(unsigned char)*numPixels);
		cudaMalloc((void**)&dev_red_template, sizeof(unsigned char)*numPixels_template);
		cudaMalloc((void**)&dev_green_template, sizeof(unsigned char)*numPixels_template);
		cudaMalloc((void**)&dev_blue_template, sizeof(unsigned char)*numPixels_template);
		cudaMalloc((void**)&dev_red_normalized, sizeof(float)*numPixels);
		cudaMalloc((void**)&dev_green_normalized, sizeof(float)*numPixels);
		cudaMalloc((void**)&dev_blue_normalized, sizeof(float)*numPixels);
		cudaMalloc((void**)&dev_normalized, sizeof(float)*numPixels);
		cudaMalloc((void**)&dev_input, sizeof(unsigned int)*numPixels);
		cudaMalloc((void**)&dev_normalized_sorted, sizeof(unsigned int)*numPixels);
		cudaMalloc((void**)&dev_ipPosition, sizeof(unsigned int)*numPixels);
		cudaMalloc((void**)&dev_opPosition, sizeof(unsigned int)*numPixels);

		cudaMemcpy(dev_red, red, sizeof(unsigned char)*numPixels, cudaMemcpyHostToDevice);
		cudaMemcpy(dev_green, green, sizeof(unsigned char)*numPixels, cudaMemcpyHostToDevice);
		cudaMemcpy(dev_blue, blue, sizeof(unsigned char)*numPixels, cudaMemcpyHostToDevice);
		cudaMemcpy(dev_red_template, red_template, sizeof(unsigned char)*numPixels_template, cudaMemcpyHostToDevice);
		cudaMemcpy(dev_green_template, green_template, sizeof(unsigned char)*numPixels_template, cudaMemcpyHostToDevice);
		cudaMemcpy(dev_blue_template, blue_template, sizeof(unsigned char)*numPixels_template, cudaMemcpyHostToDevice);

		dim3 gridSize((cols + blockSize.x - 1) / blockSize.x, (rows + blockSize.y - 1) / blockSize.y, 1);

		#if PROFILE
			GpuTimer timer;
			timer.Start();
		#endif
		naive_normalized_cross_correlation << <gridSize, blockSize >> >(dev_red_normalized, dev_red, dev_red_template,
			rows, cols, (rows_template - 1) / 2, rows_template, (cols_template - 1) / 2, cols_template,	numPixels_template, r_mean);
		cudaDeviceSynchronize();

		naive_normalized_cross_correlation << <gridSize, blockSize >> >(dev_green_normalized, dev_green, dev_green_template,
			rows, cols, (rows_template - 1) / 2, rows_template, (cols_template - 1) / 2, cols_template, numPixels_template, g_mean);
		cudaDeviceSynchronize();

		naive_normalized_cross_correlation << <gridSize, blockSize >> >(dev_blue_normalized, dev_blue, dev_blue_template,
			rows, cols, (rows_template - 1) / 2, rows_template, (cols_template - 1) / 2, cols_template, numPixels_template, b_mean);
		cudaDeviceSynchronize();
		#if PROFILE
			timer.Stop();
			printf("cross correlation: %f msecs.\n", timer.Elapsed());
		#endif

		#if PROFILE
			timer.Start();
		#endif
		create_normalized_matrix << < gridSize, blockSize >> >(dev_red_normalized, dev_green_normalized, dev_blue_normalized, dev_normalized,
			rows, cols);
		#if PROFILE
			timer.Stop();
			printf("normalized cross correlation: %f msecs.\n", timer.Elapsed());
		#endif

		float minVal = reduce_minmax(dev_normalized, numPixels, 0);

		#if PROFILE
			timer.Start();
		#endif
		mean_shift << < gridSize, blockSize >> >(dev_normalized, minVal, rows, cols);
		#if PROFILE
			timer.Stop();
			printf("mean shift: %f msecs.\n", timer.Elapsed());
		#endif

		dim3 gridSize2(ceil((float)(numPixels) / BLOCK_SIZE) + 1);
		allocatePos << <gridSize2, BLOCK_SIZE >> >(dev_ipPosition, numPixels);

		cudaMemcpy(dev_input, dev_normalized, sizeof(unsigned int)*numPixels, cudaMemcpyDeviceToDevice);
		
		sort(dev_input, dev_ipPosition, dev_normalized_sorted, dev_opPosition, numPixels);

		dim3 gridSize3((40 + BLOCK_SIZE - 1) / BLOCK_SIZE, 1, 1);
		#if PROFILE
			timer.Start();
		#endif
			remove_redness_from_coordinates << <gridSize3, BLOCK_SIZE >> >(dev_opPosition, dev_blue, dev_green,
			dev_red, 40, rows, cols, 9, 9);
		#if PROFILE
			timer.Stop();
			printf("remap: %f msecs.\n", timer.Elapsed());
		#endif
			
		cudaMemcpy(red, dev_red, sizeof(unsigned char)*numPixels, cudaMemcpyDeviceToHost);

		unsigned char *imgPtr = new unsigned char[numPixels * im.channels()];
		for (int i = 0; i < numPixels; ++i) {
			imgPtr[3 * i + 0] = blue[i];
			imgPtr[3 * i + 1] = green[i];
			imgPtr[3 * i + 2] = red[i];
		}

		int sizes[2];
		sizes[0] = rows;
		sizes[1] = cols;
		cv::Mat result(2, sizes, im.type(), (void *)imgPtr);

		cudaFree(dev_red);
		cudaFree(dev_green);
		cudaFree(dev_blue);
		cudaFree(dev_red_template);
		cudaFree(dev_green_template);
		cudaFree(dev_blue_template);
		cudaFree(dev_red_normalized);
		cudaFree(dev_green_normalized);
		cudaFree(dev_blue_normalized);
		cudaFree(dev_normalized);
		cudaFree(dev_input);
		cudaFree(dev_ipPosition);
		cudaFree(dev_opPosition);
		cudaFree(dev_normalized_sorted);

		delete[] red;
		delete[] green;
		delete[] blue;
		delete[] red_template;
		delete[] blue_template;
		delete[] green_template;

		return result;
	}
}
