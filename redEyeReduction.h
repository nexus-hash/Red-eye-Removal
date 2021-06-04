#include <stdio.h>
#include <cuda.h>
#include <vector>
#include "cuda_runtime.h"
#include <iostream>
#include <algorithm>
#include "opencv2/highgui/highgui.hpp"

using namespace std;
using namespace cv;

namespace redEyeReduction {
	Mat gpuRER(Mat im, Mat eyeTemplate);
}