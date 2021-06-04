#include "opencv2/highgui/highgui.hpp"
#include "opencv2/imgproc.hpp"
#include <iostream>
#include "redEyeReduction.h"
#include "timer.h"

#define PROFILE 1
#define REDEYEREDUCTION 0
#define BLUR 0
#define CPU 0
#define GPU 1

using namespace cv;
using namespace std;

int main(int argc, char** argv)
{
	#if PROFILE
		timerGPU.Start();
	#endif
		im = redEyeReduction::gpuRER(im, im2);
	#if PROFILE
		timerGPU.Stop();
		printf("Total GPU time: %f msecs.\n", timerGPU.Elapsed());
	#endif

	imshow("Output",im);
	
	waitKey(0);

	return 0;
}
