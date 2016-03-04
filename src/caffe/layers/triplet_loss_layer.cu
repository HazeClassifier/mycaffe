#include <algorithm>
#include <vector>

#include "caffe/layers/triplet_loss_layer.hpp"
#include "caffe/util/math_functions.hpp"
#include "caffe/util/io.hpp"
//#include "caffe/vision_layers.hpp"

namespace caffe {

template <typename Dtype>
void TripletLossLayer<Dtype>::Forward_gpu(
    const vector<Blob<Dtype>*>& bottom,
    const vector<Blob<Dtype>*>& top) {
  Dtype margin = this->layer_param_.triplet_loss_param().margin();
  Dtype losstype = this->layer_param_.triplet_loss_param().losstype();
  int num_triplets = this->layer_param_.triplet_loss_param().num_triplets();
  CHECK_EQ(bottom[0]->num()%(2 + num_triplets), 0);
  Dtype loss(0.0);
  int dim = bottom[0]->count()/bottom[0]->num();
  int num_set = bottom[0]->num()/(2 + num_triplets);
  if (losstype == 0) {
  for (int i = 0; i < num_set; ++i) {
    caffe_gpu_sub(
        dim,
        bottom[0]->gpu_data() + (2 + num_triplets)*i*dim,  // reference
        bottom[0]->gpu_data() + ((2 + num_triplets)*i + 1)*dim,  // positive
        diff_pos.mutable_gpu_data() + i*dim);  // reference-pose_close
    caffe_gpu_dot(
        dim,
        diff_pos.gpu_data() + i*dim,
        diff_pos.gpu_data() + i*dim,
        dist_sq_pos.mutable_cpu_data() + i);
    // a b is a similar pair for pair wise
    // loss accumulated by the pair wise part
    loss += dist_sq_pos.cpu_data()[i];
    for (int triplet = 0; triplet < num_triplets; ++triplet) {
      // Triplet loss accumulation
      // a and negative[triplet] is a similar pair for triplet
      dist_sq_.mutable_cpu_data()[i] = dist_sq_pos.cpu_data()[i];
      // Loss component calculated from negative part
      caffe_gpu_sub(
          dim,
          bottom[0]->gpu_data() + (2 + num_triplets)*i*dim,  // reference
          bottom[0]->gpu_data() + ((2 + num_triplets)*i + 2 + triplet)*dim,
          diff_neg.mutable_gpu_data() + i*dim);  // reference-negative
      caffe_gpu_dot(
          dim,
          diff_neg.gpu_data() + i*dim,
          diff_neg.gpu_data() + i*dim,
          dist_sq_neg.mutable_cpu_data() + i);
      // a and negative[triplet] is a dissimilar pair for triplet
      dist_sq_.mutable_cpu_data()[i] -= dist_sq_neg.cpu_data()[i];
      // loss accumulated accumulated by the triplet part
      loss += std::max(margin + dist_sq_.cpu_data()[i], Dtype(0.0));
    }
  }
  loss = loss / static_cast<Dtype>(num_set) / Dtype(2);
  top[0]->mutable_gpu_data()[0] = loss;
  } else {
  for (int i = 0; i < num_set; ++i) {
    caffe_gpu_sub(
        dim,
        bottom[0]->gpu_data() + (2 + num_triplets)*i*dim,  // reference
        bottom[0]->gpu_data() + ((2 + num_triplets)*i + 1)*dim,  // positive
        diff_pos.mutable_gpu_data() + i*dim);  // reference-pose_close
    // Loss component calculated from reference and close one
    caffe_gpu_dot(
        dim,
        diff_pos.gpu_data() + i*dim,
        diff_pos.gpu_data() + i*dim,
        dist_sq_pos.mutable_cpu_data() + i);
    // a b is a similar pair for pair wise
    // loss accumulated by the pair wise part
    loss += dist_sq_pos.cpu_data()[i];
    for (int triplet = 0; triplet < num_triplets; ++triplet) {
      dist_sq_.mutable_cpu_data()[i] = dist_sq_pos.mutable_cpu_data()[i];
      dist_sq_.mutable_cpu_data()[i] += margin;
      // Loss component calculated from negative part
      caffe_gpu_sub(
          dim,
          bottom[0]->gpu_data() + (2 + num_triplets)*i*dim,  // reference
          bottom[0]->gpu_data() + ((2 + num_triplets)*i + 2 + triplet)*dim,
          diff_neg.mutable_gpu_data() + i*dim);  // reference-negative
      caffe_gpu_dot(
          dim,
          diff_neg.gpu_data() + i*dim,
          diff_neg.gpu_data() + i*dim,
          dist_sq_neg.mutable_cpu_data() + i);
      // a and negative[triplet] is a dissimilar pair for triplet
      dist_sq_.mutable_cpu_data()[i] = 1 - \
        dist_sq_neg.cpu_data()[i] / dist_sq_.mutable_cpu_data()[i];
      // loss accumulated accumulated by the triplet part
      loss += std::max(dist_sq_.cpu_data()[i], Dtype(0.0));
    }
  }
  loss = loss / static_cast<Dtype>(num_set) / Dtype(2);
  top[0]->mutable_cpu_data()[0] = loss;
  }
}

template <typename Dtype>
void TripletLossLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
    const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom) {
  Dtype margin = this->layer_param_.triplet_loss_param().margin();
  Dtype losstype = this->layer_param_.triplet_loss_param().losstype();
  int num_triplets = this->layer_param_.triplet_loss_param().num_triplets();
  int dim = bottom[0]->count()/bottom[0]->num();
  int num_set = bottom[0]->num()/(2 + num_triplets);
  if (losstype == 0) {
  // BP for feat1(extracted from reference)
  for (int i = 0; i < 1; ++i) {
    if (propagate_down[0]) {
      const Dtype sign = 1;
      const Dtype alpha = sign * top[0]->cpu_diff()[0] /
          static_cast<Dtype>(num_set);
      for (int j = 0; j < num_set; ++j) {
        Dtype* bout = bottom[0]->mutable_gpu_diff();
        // the pair part
        caffe_gpu_axpby(
            dim,
            alpha,
            diff_pos.gpu_data() + (j*dim),
            Dtype(0.0),
            bout + ((2 + num_triplets)*j + i)*dim);
        // the num_triplets triplet part
        for (int triplet = 0; triplet < num_triplets; ++triplet) {
          caffe_gpu_sub(
              dim,
              bottom[0]->gpu_data() + (2 + num_triplets)*j*dim,  // reference
              bottom[0]->gpu_data() + ((2 + num_triplets)*j + 2 + triplet)*dim,
              diff_neg.mutable_gpu_data() + j*dim);  // reference-negative
          caffe_gpu_dot(
              dim,
              diff_neg.gpu_data() + j*dim,
              diff_neg.gpu_data() + j*dim,
              dist_sq_neg.mutable_cpu_data() + j);
          // Triplet loss accumulation
          // a and negative[triplet] is a similar pair for triplet
          dist_sq_.mutable_cpu_data()[j] = dist_sq_pos.cpu_data()[j];
          // a and negative[triplet] is a dissimilar pair for triplet
          dist_sq_.mutable_cpu_data()[j] -= dist_sq_neg.cpu_data()[j];
          // Loss component calculated from negative part
          if ((margin + dist_sq_.cpu_data()[j]) > Dtype(0.0)) {
            // similar pair in triplet
            caffe_gpu_axpby(
                dim,
                alpha,
                diff_pos.gpu_data() + (j*dim),
                Dtype(1.0),
                bout + (2 + num_triplets)*j*dim);
            // dissimilar pair in triplet
            caffe_gpu_axpby(
                dim,
                -alpha,
                diff_neg.gpu_data() + (j*dim),
                Dtype(1.0),
                bout + ((2 + num_triplets)*j + i)*dim);
          }
        }
      }
    }
  }
  // BP for feat2(extracted from the closest sample)
  for (int i = 1; i < 2; ++i) {
    if (propagate_down[0]) {
      const Dtype sign = -1;
      const Dtype alpha = sign * top[0]->cpu_diff()[0] /
          static_cast<Dtype>(num_set);
      for (int j = 0; j < num_set; ++j) {
        Dtype* bout = bottom[0]->mutable_gpu_diff();
        // the pair part
        caffe_gpu_axpby(
            dim,
            alpha,
            diff_pos.gpu_data() + (j*dim),
            Dtype(0.0),
            bout + ((2 + num_triplets)*j + i)*dim);
        // the num_triplets triplet part
        for (int triplet = 0; triplet < num_triplets; ++triplet) {
          caffe_gpu_sub(
              dim,
              bottom[0]->gpu_data() + (2 + num_triplets)*j*dim,  // reference
              bottom[0]->gpu_data() + ((2 + num_triplets)*j + 2 + triplet)*dim,
              diff_neg.mutable_gpu_data() + j*dim);  // reference-negative
          // Triplet loss accumulation
          // a and negative[triplet] is a similar pair for triplet
          dist_sq_.mutable_cpu_data()[j] = dist_sq_pos.cpu_data()[j];
          caffe_gpu_dot(
              dim,
              diff_neg.gpu_data() + j*dim,
              diff_neg.gpu_data() + j*dim,
              dist_sq_neg.mutable_cpu_data() + j);
          // a and negative[triplet] is a dissimilar pair for triplet
          dist_sq_.mutable_cpu_data()[j] -= dist_sq_neg.cpu_data()[j];
          if ((margin + dist_sq_.cpu_data()[j]) > Dtype(0.0)) {
            // similar pair in triplet
            caffe_gpu_axpby(
                dim,
                alpha,
                diff_pos.gpu_data() + (j*dim),
                Dtype(1.0),
                bout + ((2 + num_triplets)*j + i)*dim);
          }
        }
      }
    }
  }
  // BP for negative feature used in the num_triplets triplet part
  for (int i = 2; i < 2 + num_triplets; ++i) {
    if (propagate_down[0]) {
      const Dtype sign = 1;
      const Dtype alpha = sign * top[0]->cpu_diff()[0] /
          static_cast<Dtype>(num_set);
      for (int j = 0; j < num_set; ++j) {
        Dtype* bout = bottom[0]->mutable_gpu_diff();
        caffe_gpu_sub(
            dim,
            bottom[0]->gpu_data() + (2 + num_triplets)*j*dim,  // reference
            bottom[0]->gpu_data() + ((2 + num_triplets)*j + i)*dim,
            diff_neg.mutable_gpu_data() + j*dim);  // reference-negative
        // Triplet loss accumulation
        // a and negative[triplet] is a similar pair for triplet
        dist_sq_.mutable_cpu_data()[j] = dist_sq_pos.cpu_data()[j];
        caffe_gpu_dot(
            dim,
            diff_neg.gpu_data() + j*dim,
            diff_neg.gpu_data() + j*dim,
            dist_sq_neg.mutable_cpu_data() + j);
        // a and negative[triplet] is a dissimilar pair for triplet
        dist_sq_.mutable_cpu_data()[j] -= dist_sq_neg.cpu_data()[j];
        if ((margin + dist_sq_.cpu_data()[j]) > Dtype(0.0)) {
          // dissimilar pairs
          caffe_gpu_axpby(
              dim,
              alpha,
              diff_neg.gpu_data() + (j*dim),
              Dtype(0.0),
              bout + ((2 + num_triplets)*j + i)*dim);
        } else {
            caffe_gpu_set(dim, Dtype(0), bout + ((2 + num_triplets)*j + i)*dim);
        }
      }
    }
  }
  } else {
  for (int i = 0; i < 1; ++i) {
    // BP for data1(feat1)
    if (propagate_down[0]) {
      const Dtype sign = 1;
      const Dtype alpha = sign * top[0]->cpu_diff()[0] /
          static_cast<Dtype>(num_set);
      for (int j = 0; j < num_set; ++j) {
        Dtype* bout = bottom[0]->mutable_gpu_diff();
        // the pair part
        caffe_gpu_axpby(
            dim,
            alpha,
            diff_pos.gpu_data() + (j*dim),
            Dtype(0.0),
            bout + ((2 + num_triplets)*j + i)*dim);
        // the num_triplets triplet part
        for (int triplet = 0; triplet < num_triplets; ++triplet) {
          dist_sq_.mutable_cpu_data()[j] = dist_sq_pos.mutable_cpu_data()[j];
          dist_sq_.mutable_cpu_data()[j] += margin;
          // Loss component calculated from negative part
          caffe_gpu_sub(
              dim,
              bottom[0]->gpu_data() + (2 + num_triplets)*j*dim,  // reference
              bottom[0]->gpu_data() + ((2 + num_triplets)*j + 2 + triplet)*dim,
              diff_neg.mutable_gpu_data() + j*dim);  // reference-negative
          caffe_gpu_dot(
              dim,
              diff_neg.gpu_data() + j*dim,
              diff_neg.gpu_data() + j*dim,
              dist_sq_neg.mutable_cpu_data() + j);
          // a and negative[triplet] is a dissimilar pair for triplet
          dist_sq_.mutable_cpu_data()[j] = 1 - \
            dist_sq_neg.cpu_data()[j] / dist_sq_.mutable_cpu_data()[j];
          // loss accumulated accumulated by the triplet part
          if ((dist_sq_.cpu_data()[j]) > Dtype(0.0)) {
            caffe_gpu_axpby(
                dim,
                alpha*dist_sq_neg.mutable_cpu_data()[j]\
  /((dist_sq_pos.mutable_cpu_data()[j]+margin)\
  *(dist_sq_pos.mutable_cpu_data()[j]+margin)),
                diff_pos.gpu_data() + (j*dim),
                Dtype(1.0),
                bout + ((2 + num_triplets)*j + i)*dim);
            caffe_gpu_axpby(
                dim,
                -alpha/(dist_sq_pos.mutable_cpu_data()[j] + margin),
                diff_neg.gpu_data() + (j*dim),
                Dtype(1.0),
                bout + ((2 + num_triplets)*j + i)*dim);
          }
        }
      }
    }
  }
  for (int i = 1; i < 2; ++i) {
    // BP for positive data(feat2)
    if (propagate_down[0]) {
      const Dtype sign = -1;
      const Dtype alpha = sign * top[0]->cpu_diff()[0] /
          static_cast<Dtype>(num_set);
      for (int j = 0; j < num_set; ++j) {
        Dtype* bout = bottom[0]->mutable_gpu_diff();
        // the pair part
        caffe_gpu_axpby(
            dim,
            alpha,
            diff_pos.gpu_data() + (j*dim),
            Dtype(0.0),
            bout + ((2 + num_triplets)*j + i)*dim);
        // the num_triplets triplet part
        for (int triplet = 0; triplet < num_triplets; ++triplet) {
          dist_sq_.mutable_cpu_data()[j] = dist_sq_pos.mutable_cpu_data()[j];
          dist_sq_.mutable_cpu_data()[j] += margin;
          // Loss component calculated from negative part
          caffe_gpu_sub(
              dim,
              bottom[0]->gpu_data() + (2 + num_triplets)*j*dim,  // reference
              bottom[0]->gpu_data() + ((2 + num_triplets)*j + 2 + triplet)*dim,
              diff_neg.mutable_gpu_data() + j*dim);  // reference-negative
          caffe_gpu_dot(
              dim,
              diff_neg.gpu_data() + j*dim,
              diff_neg.gpu_data() + j*dim,
              dist_sq_neg.mutable_cpu_data() + j);
          // a and negative[triplet] is a dissimilar pair for triplet
          dist_sq_.mutable_cpu_data()[j] = 1 - \
            dist_sq_neg.cpu_data()[j] / dist_sq_.mutable_cpu_data()[j];
          // loss accumulated accumulated by the triplet part
          if ((dist_sq_.cpu_data()[j]) > Dtype(0.0)) {
            caffe_gpu_axpby(
                dim,
                alpha*dist_sq_neg.mutable_cpu_data()[j]\
  /((dist_sq_pos.mutable_cpu_data()[j]+margin)\
  *(dist_sq_pos.mutable_cpu_data()[j]+margin)),
                diff_pos.gpu_data() + (j*dim),
                Dtype(1.0),
                bout + ((2 + num_triplets)*j + i)*dim);
          }
        }
      }
    }
  }
  for (int i = 2; i < 2 + num_triplets; ++i) {
    // BP for negative data(feat3)
    if (propagate_down[0]) {
      const Dtype sign = 1;
      const Dtype alpha = sign * top[0]->cpu_diff()[0] /
          static_cast<Dtype>(num_set);
      for (int j = 0; j < num_set; ++j) {
        Dtype* bout = bottom[0]->mutable_gpu_diff();
        dist_sq_.mutable_cpu_data()[j] = dist_sq_pos.mutable_cpu_data()[j];
        dist_sq_.mutable_cpu_data()[j] += margin;
        // Loss component calculated from negative part
        caffe_gpu_sub(
            dim,
            bottom[0]->gpu_data() + (2 + num_triplets)*j*dim,  // reference
            bottom[0]->gpu_data() + ((2 + num_triplets)*j + i)*dim,
            diff_neg.mutable_gpu_data() + j*dim);  // reference-negative
        caffe_gpu_dot(
            dim,
            diff_neg.gpu_data() + j*dim,
            diff_neg.gpu_data() + j*dim,
            dist_sq_neg.mutable_cpu_data() + j);
        // a and negative[triplet] is a dissimilar pair for triplet
        dist_sq_.mutable_cpu_data()[j] = 1 - \
          dist_sq_neg.cpu_data()[j] / dist_sq_.mutable_cpu_data()[j];
        // loss accumulated accumulated by the triplet part
        if ((dist_sq_.cpu_data()[j]) > Dtype(0.0)) {
          caffe_gpu_axpby(
              dim,
              alpha/(dist_sq_pos.mutable_cpu_data()[j] + margin),
              diff_neg.gpu_data() + (j*dim),
              Dtype(0.0),
              bout + ((2 + num_triplets)*j + i)*dim);
        } else {
            caffe_gpu_set(dim, Dtype(0), bout + ((2 + num_triplets)*j + i)*dim);
        }
      }
    }
  }
  }
}

INSTANTIATE_LAYER_GPU_FUNCS(TripletLossLayer);

}  // namespace caffe
