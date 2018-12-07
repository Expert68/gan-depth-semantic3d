// ---------------------------------------------------------
// Author: Andy Zeng, Princeton University, 2016
// ---------------------------------------------------------

#include <iostream>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>
#include "utils.hpp"

// CUDA kernel function to integrate a TSDF voxel volume given depth images
__global__
void Integrate(float * cam_K, float * cam2base, float * depth_im,
               int im_height, int im_width, int voxel_grid_dim_x, int voxel_grid_dim_y, int voxel_grid_dim_z,
               float voxel_grid_origin_x, float voxel_grid_origin_y, float voxel_grid_origin_z, float voxel_size, float trunc_margin,
               float * voxel_grid_TSDF) {

  int pt_grid_z = blockIdx.x;
  int pt_grid_y = threadIdx.x;

  for (int pt_grid_x = 0; pt_grid_x < voxel_grid_dim_x; ++pt_grid_x) {

    // Convert voxel center from grid coordinates to base frame camera coordinates
    float pt_base_x = voxel_grid_origin_x + pt_grid_x * voxel_size;
    float pt_base_y = voxel_grid_origin_y + pt_grid_y * voxel_size;
    float pt_base_z = voxel_grid_origin_z + pt_grid_z * voxel_size;

    // Convert from base frame camera coordinates to current frame camera coordinates
    float tmp_pt[3] = {0};
    tmp_pt[0] = pt_base_x - cam2base[0 * 4 + 3];
    tmp_pt[1] = pt_base_y - cam2base[1 * 4 + 3];
    tmp_pt[2] = pt_base_z - cam2base[2 * 4 + 3];
    float pt_cam_x = cam2base[0 * 4 + 0] * tmp_pt[0] + cam2base[1 * 4 + 0] * tmp_pt[1] + cam2base[2 * 4 + 0] * tmp_pt[2];
    float pt_cam_y = cam2base[0 * 4 + 1] * tmp_pt[0] + cam2base[1 * 4 + 1] * tmp_pt[1] + cam2base[2 * 4 + 1] * tmp_pt[2];
    float pt_cam_z = cam2base[0 * 4 + 2] * tmp_pt[0] + cam2base[1 * 4 + 2] * tmp_pt[1] + cam2base[2 * 4 + 2] * tmp_pt[2];

    int volume_idx = pt_grid_z * voxel_grid_dim_y * voxel_grid_dim_x + pt_grid_y * voxel_grid_dim_x + pt_grid_x;
    if (pt_cam_z <= 0) {
      voxel_grid_TSDF[volume_idx] = -2.0f;
      continue;
    }

    int pt_pix_x = roundf(cam_K[0 * 3 + 0] * (pt_cam_x / pt_cam_z) + cam_K[0 * 3 + 2]);
    int pt_pix_y = roundf(cam_K[1 * 3 + 1] * (pt_cam_y / pt_cam_z) + cam_K[1 * 3 + 2]);
    if (pt_pix_x < 0 || pt_pix_x >= im_width || pt_pix_y < 0 || pt_pix_y >= im_height) {
      voxel_grid_TSDF[volume_idx] = -2.0f;
      continue;
    }

    float depth_val = depth_im[pt_pix_y * im_width + pt_pix_x];

    if (depth_val > 8) {
      voxel_grid_TSDF[volume_idx] = -2.0f;
      continue;
    }

    float diff = depth_val - pt_cam_z;

    // This is for labeling the -1 space (occluded space)
    if (diff < -0.1 || depth_val == 0.0) {
      voxel_grid_TSDF[volume_idx] = 2.0f;
      continue;
    }

    // This is for labeling the empty space
    if (diff > 0.1) {
      voxel_grid_TSDF[volume_idx] = -1.0f;
      continue;
    }

    // Integrate
    // float dist = fmin(1.0f, diff / trunc_margin);
    // float weight_old = voxel_grid_weight[volume_idx];
    // float weight_new = weight_old + 1.0f;
    // voxel_grid_weight[volume_idx] = weight_new;
    // voxel_grid_TSDF[volume_idx] = (voxel_grid_TSDF[volume_idx] * weight_old + dist) / weight_new;
    if (abs(diff) < 0.1) {
      voxel_grid_TSDF[volume_idx] = 1.0f;
    }
  }
}

// Loads a binary file with depth data and generates a TSDF voxel volume (5m x 5m x 5m at 1cm resolution)
// Volume is aligned with respect to the camera coordinates of the first frame (a.k.a. base frame)
int main(int argc, char * argv[]) {

  // Location of camera intrinsic file
  std::string cam_K_file = "data/camera-intrinsics.txt";
  std::string cam_origin_file = "data/origin/00017227_01e40e56e7c4006efc920560ac4d26b9_fl001_rm0004_0000.txt";
  std::string base2world_file = "data/camera/00017227_01e40e56e7c4006efc920560ac4d26b9_fl001_rm0004_0000.txt";
  std::string depth_im_file = "data/depth_real_png/00017227_01e40e56e7c4006efc920560ac4d26b9_fl001_rm0004_0000.png";
  std::string tsdf_bin_file = "tsdf.bin";

  // Location of folder containing RGB-D frames and camera pose files
  // std::string data_path = "data/rgbd-frames-yida";

  float cam_K[3 * 3];
  float cam_origin[3 * 1];
  float base2world[4 * 4];
  float cam2base[4 * 4];
  float cam2world[4 * 4];
  int im_width = 640;
  int im_height = 480;
  float depth_im[im_height * im_width];

  // Voxel grid parameters (change these to change voxel grid resolution, etc.)
  float voxel_grid_origin_x = 43.15f; // Location of voxel grid origin in base frame camera coordinates
  float voxel_grid_origin_y = 50.88f;
  float voxel_grid_origin_z = 0.05f;
  float voxel_size = 0.06f;
  float trunc_margin = 0.72f;//voxel_size * 5;
  int voxel_grid_dim_x = 80;
  int voxel_grid_dim_y = 80;
  int voxel_grid_dim_z = 48;

  // Manual parameters
  if (argc > 1) {
    cam_K_file = argv[1];
    cam_origin_file = argv[2];
    base2world_file = argv[3];
    depth_im_file = argv[4];
    tsdf_bin_file = argv[5];
  }

  // Read camera intrinsics
  std::vector<float> cam_K_vec = LoadMatrixFromFile(cam_K_file, 3, 3);
  std::copy(cam_K_vec.begin(), cam_K_vec.end(), cam_K);
  std::vector<float> cam_origin_vec = LoadMatrixFromFile(cam_origin_file, 3, 1);
  std::copy(cam_origin_vec.begin(), cam_origin_vec.end(), cam_origin);
  voxel_grid_origin_x = cam_origin[0];
  voxel_grid_origin_y = cam_origin[1];
  voxel_grid_origin_z = cam_origin[2];

  // Read base frame camera pose
  std::ostringstream base_frame_prefix;
  // base_frame_prefix << std::setw(6) << std::setfill('0') << base_frame_idx;
  // std::string base2world_file = data_path + "/frame-" + base_frame_prefix.str() + ".pose.txt";
  std::vector<float> base2world_vec = LoadMatrixFromFile(base2world_file, 4, 4);
  std::copy(base2world_vec.begin(), base2world_vec.end(), base2world);

  // Invert base frame camera pose to get world-to-base frame transform
  float base2world_inv[16] = {0};
  invert_matrix(base2world, base2world_inv);

  // Initialize voxel grid
  float * voxel_grid_TSDF = new float[voxel_grid_dim_x * voxel_grid_dim_y * voxel_grid_dim_z];
  for (int i = 0; i < voxel_grid_dim_x * voxel_grid_dim_y * voxel_grid_dim_z; ++i)
    voxel_grid_TSDF[i] = 0.0f;

  // Load variables to GPU memory
  float * gpu_voxel_grid_TSDF;
  cudaMalloc(&gpu_voxel_grid_TSDF, voxel_grid_dim_x * voxel_grid_dim_y * voxel_grid_dim_z * sizeof(float));
  checkCUDA(__LINE__, cudaGetLastError());
  cudaMemcpy(gpu_voxel_grid_TSDF, voxel_grid_TSDF, voxel_grid_dim_x * voxel_grid_dim_y * voxel_grid_dim_z * sizeof(float), cudaMemcpyHostToDevice);
  checkCUDA(__LINE__, cudaGetLastError());
  float * gpu_cam_K;
  float * gpu_cam2base;
  float * gpu_depth_im;
  cudaMalloc(&gpu_cam_K, 3 * 3 * sizeof(float));
  cudaMemcpy(gpu_cam_K, cam_K, 3 * 3 * sizeof(float), cudaMemcpyHostToDevice);
  cudaMalloc(&gpu_cam2base, 4 * 4 * sizeof(float));
  cudaMalloc(&gpu_depth_im, im_height * im_width * sizeof(float));
  checkCUDA(__LINE__, cudaGetLastError());

  // Loop through each depth frame and integrate TSDF voxel grid

    // std::ostringstream curr_frame_prefix;
    // curr_frame_prefix << std::setw(6) << std::setfill('0') << frame_idx;

    // // Read current frame depth
    // std::string depth_im_file = data_path + "/frame-" + curr_frame_prefix.str() + ".depth.png";
    ReadDepth(depth_im_file, im_height, im_width, depth_im);

    // Read base frame camera pose
    std::string cam2world_file = base2world_file; //data_path + "/frame-" + curr_frame_prefix.str() + ".pose.txt";
    std::vector<float> cam2world_vec = LoadMatrixFromFile(cam2world_file, 4, 4);
    std::copy(cam2world_vec.begin(), cam2world_vec.end(), cam2world);

    // Compute relative camera pose (camera-to-base frame)
    multiply_matrix(base2world_inv, cam2world, cam2base);

    // yida: here we should use base2world for rotation for alignment of the ground
    cudaMemcpy(gpu_cam2base, base2world, 4 * 4 * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_depth_im, depth_im, im_height * im_width * sizeof(float), cudaMemcpyHostToDevice);
    checkCUDA(__LINE__, cudaGetLastError());

    // std::cout << "Fusing: " << depth_im_file << std::endl;

    Integrate <<< voxel_grid_dim_z, voxel_grid_dim_y >>>(gpu_cam_K, gpu_cam2base, gpu_depth_im,
                                                         im_height, im_width, voxel_grid_dim_x, voxel_grid_dim_y, voxel_grid_dim_z,
                                                         voxel_grid_origin_x, voxel_grid_origin_y, voxel_grid_origin_z, voxel_size, trunc_margin,
                                                         gpu_voxel_grid_TSDF);

  // Load TSDF voxel grid from GPU to CPU memory
  cudaMemcpy(voxel_grid_TSDF, gpu_voxel_grid_TSDF, voxel_grid_dim_x * voxel_grid_dim_y * voxel_grid_dim_z * sizeof(float), cudaMemcpyDeviceToHost);
  // cudaMemcpy(voxel_grid_weight, gpu_voxel_grid_weight, voxel_grid_dim_x * voxel_grid_dim_y * voxel_grid_dim_z * sizeof(float), cudaMemcpyDeviceToHost);
  checkCUDA(__LINE__, cudaGetLastError());

  // Compute surface points from TSDF voxel grid and save to point cloud .ply file
  // std::cout << "Saving surface point cloud (tsdf.ply)..." << std::endl;
  
  SaveVoxelGrid2SurfacePointCloud("tsdf.ply", voxel_grid_dim_x, voxel_grid_dim_y, voxel_grid_dim_z,
                                  voxel_size, voxel_grid_origin_x, voxel_grid_origin_y, voxel_grid_origin_z,
                                  voxel_grid_TSDF);

  // Save TSDF voxel grid and its parameters to disk as binary file (float array)
  // std::cout << "Saving TSDF voxel grid values to disk (tsdf.bin)..." << std::endl;
  std::ofstream outFile(tsdf_bin_file, std::ios::binary | std::ios::out);
  /*
  float voxel_grid_dim_xf = (float) voxel_grid_dim_x;
  float voxel_grid_dim_yf = (float) voxel_grid_dim_y;
  float voxel_grid_dim_zf = (float) voxel_grid_dim_z;
  outFile.write((char*)&voxel_grid_dim_xf, sizeof(float));
  outFile.write((char*)&voxel_grid_dim_yf, sizeof(float));
  outFile.write((char*)&voxel_grid_dim_zf, sizeof(float));
  outFile.write((char*)&voxel_grid_origin_x, sizeof(float));
  outFile.write((char*)&voxel_grid_origin_y, sizeof(float));
  outFile.write((char*)&voxel_grid_origin_z, sizeof(float));
  outFile.write((char*)&voxel_size, sizeof(float));
  outFile.write((char*)&trunc_margin, sizeof(float));
  */
  for (int i = 0; i < voxel_grid_dim_x * voxel_grid_dim_y * voxel_grid_dim_z; ++i) {
    outFile.write((char*)&voxel_grid_TSDF[i], sizeof(float));
  }
  outFile.close();

  return 0;
}
