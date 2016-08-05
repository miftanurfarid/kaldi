#!/bin/bash

# this script has common stages shared across AMI chain recipes


#local/chain_cleanup/run_tdnn.sh --mic ihm --train-set train_cleaned2  --gmm tri4a_cleaned2  --stage 11 &

set -e -o pipefail

# First the options that are passed through to run_ivector_common.sh
# (some of which are also used in this script directly).
stage=0
mic=ihm
nj=30
min_seg_len=1.55
train_set=train_cleaned2
gmm=tri4a_cleaned2
num_threads_ubm=32
affix=_cleaned2  # cleanup affix for exp dirs, e.g. _cleaned2

# The rest are configs specific to this script.  Most of the parameters
# are just hardcoded at this level, in the commands below.
train_stage=-10
tree_affix=  # affix for tree directory, e.g. "a" or "b", in case we change the configuration.
tdnn_affix=  #affix for TDNN directory, e.g. "a" or "b", in case we change the configuration.
common_egs_dir=  # you can set this to use previously dumped egs.


# End configuration section.
echo "$0 $@"  # Print the command line for logging

. cmd.sh
. ./path.sh
. ./utils/parse_options.sh


if ! cuda-compiled; then
  cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi

local/nnet3_cleanup/run_ivector_common.sh --stage $stage \
                                  --mic $mic \
                                  --nj $nj \
                                  --min-seg-len $min_seg_len \
                                  --train-set $train_set \
                                  --gmm $gmm \
                                  --num-threads-ubm $num_threads_ubm \
                                  --affix $affix


gmm_dir=exp/$mic/$gmm
ali_dir=${gmm_dir}_ali_sp_comb
train_data_dir=data/$mic/${train_set}_sp_hires_comb
train_ivector_dir=exp/$mic/nnet3${affix}/ivectors_${train_set}_sp_hires_comb
final_lm=`cat data/local/lm/final_lm`
LM=$final_lm.pr1-7
treedir=exp/$mic/chain${affix}/tree${tree_affix}
lat_dir=exp/$mic/chain${affix}/${gmm_dir}_${train_set}_sp_comb_lats
dir=exp/$mic/chain${affix}/tdnn${tdnn_affix}_sp

if [ $stage -le 11 ]; then
  echo "$0: creating lang directory with one state per phone."
  # Create a version of the lang/ directory that has one state per phone in the
  # topo file. [note, it really has two states.. the first one is only repeated
  # once, the second one has zero or more repeats.]
  if [ -d data/lang_chain ]; then
    if [ data/lang_chain/L.fst -nt data/lang/L.fst ]; then
      echo "$0: data/lang_chain already exists, not overwriting it; continuing"
    else
      echo "$0: data/lang_chain already exists and seems to be older than data/lang..."
      echo " ... not sure what to do.  Exiting."
      exit 1;
    fi
  else
    cp -r data/lang data/lang_chain
    silphonelist=$(cat data/lang_chain/phones/silence.csl) || exit 1;
    nonsilphonelist=$(cat data/lang_chain/phones/nonsilence.csl) || exit 1;
    # Use our special topology... note that later on may have to tune this
    # topology.
    steps/nnet3/chain/gen_topo.py $nonsilphonelist $silphonelist >data/lang_chain/topo
  fi
fi

if [ $stage -le 12 ]; then
  # Build a tree using our new topology.  We know we have alignments for the
  # speed-perturbed data (local/nnet3/run_ivector_common.sh made them), so use
  # those.
  if [ -f $treedir/final.mdl ]; then
    echo "$0: $treedir/final.mdl already exists, refusing to overwrite it."
    exit 1;
  fi
  steps/nnet3/chain/build_tree.sh --frame-subsampling-factor 3 \
      --leftmost-questions-truncate -1 \
      --cmd "$train_cmd" 4200 data/$mic/${train_set}_sp_comb data/lang_chain $ali_dir $treedir
fi


if [ $stage -le 14 ]; then
  # Get the alignments as lattices (gives the chain training more freedom).
  # use the same num-jobs as the alignments
  steps/align_fmllr_lats.sh --nj 100 --cmd "$train_cmd" data/$mic/${train_set}_sp_comb \
    data/lang $gmm_dir $lat_dir
  rm $lat_dir/fsts.*.gz # save space
fi

if [ $stage -le 15 ]; then
  mkdir -p $dir

  echo "$0: creating neural net configs";

  steps/nnet3/tdnn/make_configs.py \
    --self-repair-scale 0.00001 \
    --feat-dir data/$mic/${train_set}_sp_hires_comb \
    --ivector-dir $train_ivector_dir \
    --tree-dir $treedir \
    --relu-dim 450 \
    --splice-indexes "-1,0,1 -1,0,1,2 -3,0,3 -3,0,3 -3,0,3 -6,-3,0 0" \
    --use-presoftmax-prior-scale false \
    --xent-regularize 0.1 \
    --xent-separate-forward-affine true \
    --include-log-softmax false \
    --final-layer-normalize-target 1.0 \
   $dir/configs || exit 1;
fi

if [ $stage -le 16 ]; then
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $dir/egs/storage ]; then
    utils/create_split_dir.pl \
     /export/b0{5,6,7,8}/$USER/kaldi-data/egs/ami-$(date +'%m_%d_%H_%M')/s5/$dir/egs/storage $dir/egs/storage
  fi

 touch $dir/egs/.nodelete # keep egs around when that run dies.

 steps/nnet3/chain/train.py --stage $train_stage \
    --cmd "$decode_cmd" \
    --feat.online-ivector-dir $train_ivector_dir \
    --feat.cmvn-opts "--norm-means=false --norm-vars=false" \
    --chain.xent-regularize 0.1 \
    --chain.leaky-hmm-coefficient 0.1 \
    --chain.l2-regularize 0.00005 \
    --chain.apply-deriv-weights false \
    --chain.lm-opts="--num-extra-lm-states=2000" \
    --egs.dir "$common_egs_dir" \
    --egs.opts "--frames-overlap-per-eg 0" \
    --egs.chunk-width 150 \
    --trainer.num-chunk-per-minibatch 128 \
    --trainer.frames-per-iter 1500000 \
    --trainer.num-epochs 4 \
    --trainer.optimization.num-jobs-initial 2 \
    --trainer.optimization.num-jobs-final 12 \
    --trainer.optimization.initial-effective-lrate 0.001 \
    --trainer.optimization.final-effective-lrate 0.0001 \
    --trainer.max-param-change 2.0 \
    --cleanup.remove-egs true \
    --feat-dir $train_data_dir \
    --tree-dir $treedir \
    --lat-dir $lat_dir \
    --dir $dir
fi


graph_dir=$dir/graph_${LM}
if [ $stage -le 17 ]; then
  # Note: it might appear that this data/lang_chain directory is mismatched, and it is as
  # far as the 'topo' is concerned, but this script doesn't read the 'topo' from
  # the lang directory.
  utils/mkgraph.sh --self-loop-scale 1.0 data/lang_${LM} $dir $graph_dir
fi

if [ $stage -le 18 ]; then
  rm $dir/.error 2>/dev/null || true
  for decode_set in dev eval; do
      (
      num_jobs=`cat data/$mic/${decode_set}_hires/utt2spk|cut -d' ' -f2|sort -u|wc -l`

      steps/nnet3/decode.sh --acwt 1.0 --post-decode-acwt 10.0 \
          --nj $num_jobs --cmd "$decode_cmd" \
          --online-ivector-dir exp/$mic/nnet3${affix}/ivectors_${decode_set}_hires \
          --scoring-opts "--min-lmwt 5 " \
         $graph_dir data/$mic/${decode_set}_hires $dir/decode_${decode_set} || exit 1;
      ) || touch $dir/.error &
  done
  wait
  if [ -f $dir/.error ]; then
    echo "$0: something went wrong in decoding"
    exit 1
  fi
fi
exit 0