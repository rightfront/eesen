#!/bin/bash

. ./cmd.sh ## You'll want to change cmd.sh to something that will work on your system.
           ## This relates to the queue.
stage=4
#wsj0=/path/to/LDC93S6B
#wsj1=/path/to/LDC94S13B
fisher=/home/ec2-user/SpeakEasy/LDC_Data

#. parse_options.sh

if [ $stage -le 1 ]; then
  echo =====================================================================
  echo "             Data Preparation and FST Construction                 "
  echo =====================================================================
##first need to modify a transcript with a duplicate line that causes trouble...
 
  sed -i.ori 's/fe_03_11487-B-003109-023406/fe_03_11487-B-003109-003406/g' $fisher/fe_03_p2_tran/data/trans/114/fe_03_11487.txt 
  if [ $(grep -c 358.43 $fisher/fe_03_p2_tran/data/trans/115/fe_03_11587.txt) -ge 2 ]; then
    mv $fisher/fe_03_p2_tran/data/trans/115/fe_03_11587.txt $fisher/fe_03_p2_tran/data/trans/115/fe_03_11587.ori
    sed -e "$(grep -n 358.43 $fisher/fe_03_p2_tran/data/trans/115/fe_03_11587.ori | \
      sed -n 's/^\([[:digit:]]*\):.*/\1/p' | head -n 1)d" \
    $fisher/fe_03_p2_tran/data/trans/115/fe_03_11587.ori > $fisher/fe_03_p2_tran/data/trans/115/fe_03_11587.txt 
  fi

 # Use the same datap prepatation script from Kaldi
  local/fisher_data_prep.sh $fisher/  || exit 1;

## char_dict depends on phone_dict so adding the below
  local/fisher_prepare_phn_dict.sh || exit 1;

  # Represent word spellings using a dictionary-like format
  local/fisher_prepare_char_dict.sh || exit 1;

## below lines added to create LM that wsj does by default but fisher does not.

  #convert lexicon to lowercase

  sed -i 's/\(.*\)/\L\1/' data/local/dict_char/*.txt

  #build LM (wsj handles this in wsj_data_prep.sh ...)

  local/fisher_train_lms.sh

  # Compile the lexicon and token FSTs
  utils/ctc_compile_dict_token.sh --dict-type "char" --space-char "<space>" \
    data/local/dict_char data/local/lang_char_tmp data/lang_char || exit 1;

  # Compile the language-model FST and the final decoding graph TLG.fst
  local/fisher_decode_graph.sh data/lang_char || exit 1;
fi

if [ $stage -le 2 ]; then
  echo =====================================================================
  echo "                 Vocabulary Expansion with OOVs                    "
  echo =====================================================================
  # This part demonstrates how to include OOV words into decoding. This is a special advantage of modeling
  # characters since no G2P is required.
  {
    # Add OOVs that appear at least twice in the training transcripts 
    local/fisher_expand_vocab.sh data/train_all data/local/dict_char data/local/dict_char_larger || exit 1;
    utils/ctc_compile_dict_token.sh --dict-type "char" --space-char "<space>" \
      data/local/dict_char_larger data/local/lang_char_larger_tmp data/lang_char_larger || exit 1;
    # Retrain language models and recompile the decoding graph
    ##thanks to the above, we've now merged the wsj and fisher formats, so we can use wsj scripts here...
    local/wsj_train_lms.sh || exit 1;
    local/wsj_decode_graph_local_lms.sh data/lang_char_larger || exit 1; 
  }
fi

if [ $stage -le 3 ]; then
  echo =====================================================================
  echo "                    FBank Feature Generation                       "
  echo =====================================================================

  ##probably need to split off an evaluation set also, wsj_data_prep has this, fisher_data_prep looks like it doesn't
  ## might also need 'dev' set?  right now just commented out...

  # Split the whole training data into training (95%) and cross-validation (5%) sets
  utils/subset_data_dir_tr_cv.sh --cv-spk-percent 5 data/train_all data/train_tr95 data/train_cv05 || exit 1;

  #pick the first 600k utterances out of the training set (full set seems to cause memory errors, will need to investigate)
  utils/subset_data_dir.sh --first data/train_tr95 600000 data/train_600k;

  utils/subset_data_dir_tr_cv.sh --cv-spk-percent 20 data/train_600k data/train_tr80 data/test_deval;

  utils/subset_data_dir_tr_cv.sh --cv-spk-percent 50 data/test_deval data/test_dev93 data/test_eval92;

  # Generate the fbank features; by default 40-dimensional fbanks on each frame
  fbankdir=fbank
  for set in train_tr80 train_cv05; do
    steps/make_fbank.sh --cmd "$train_cmd" --nj 14 data/$set exp/make_fbank/$set $fbankdir || exit 1;
    utils/fix_data_dir.sh data/$set || exit;
    steps/compute_cmvn_stats.sh data/$set exp/make_fbank/$set $fbankdir || exit 1;
  done

  for set in test_dev93 test_eval92; do
    steps/make_fbank.sh --cmd "$train_cmd" --nj 8 data/$set exp/make_fbank/$set $fbankdir || exit 1;
    utils/fix_data_dir.sh data/$set || exit;
    steps/compute_cmvn_stats.sh data/$set exp/make_fbank/$set $fbankdir || exit 1;
  done
fi

if [ $stage -le 4 ]; then
  echo =====================================================================
  echo "                        Network Training                           "
  echo =====================================================================
  # Specify network structure and generate the network topology
  input_feat_dim=120   # dimension of the input features; we will use 40-dimensional fbanks with deltas and double deltas
  lstm_layer_num=4     # number of LSTM layers
  lstm_cell_dim=320    # number of memory cells in every LSTM layer

  dir=exp/train_char_l${lstm_layer_num}_c${lstm_cell_dim}   # working directory
  mkdir -p $dir

  target_num=`cat data/local/dict_char/units.txt | wc -l`; target_num=$[$target_num+1];  # the number of targets 
 
                                                        # equals [the number of labels] + 1 (the blank)

##below commented out temporarily for multi-gpu testing
  # Output the network topology
  utils/model_topo.py --input-feat-dim $input_feat_dim --lstm-layer-num $lstm_layer_num \
    --lstm-cell-dim $lstm_cell_dim --target-num $target_num > $dir/nnet.proto || exit 1;
  echo "Network topology written to $dir/nnet.proto"

  # Label sequences; simply convert words into their label indices 
  utils/prep_ctc_trans.py data/lang_char/lexicon_numbers.txt \
    data/train_tr80/text "<unk>" "<space>" | gzip -c - > $dir/labels.tr.gz
  utils/prep_ctc_trans.py data/lang_char/lexicon_numbers.txt \
    data/train_cv05/text "<unk>" "<space>" | gzip -c - > $dir/labels.cv.gz

  # Train the network with CTC. Refer to the script for details about the arguments
  steps/train_ctc_parallel.sh --add-deltas true --num-sequence 10 --frame-num-limit 15000 \
    --learn-rate 0.00004 --report-step 1000 \
     data/train_tr80 data/train_cv05 $dir || exit 1;
## try to train on small data set to debug memory error...
#    data/train_cv05 data/train_cv05 $dir || exit 1;
  echo =====================================================================
  echo "                            Decoding                               "
  echo =====================================================================
  # Decoding with the basic vocabulary (from the CMU dict)
  for lm_suffix in tgpr tg; do
    steps/decode_ctc_lat.sh --cmd "$decode_cmd" --nj 10 --beam 17.0 --lattice_beam 8.0 --max-active 5000 --acwt 0.9 \
      data/lang_char_test_${lm_suffix} data/test_dev93 $dir/decode_dev93_${lm_suffix} || exit 1;
    steps/decode_ctc_lat.sh --cmd "$decode_cmd" --nj 8 --beam 17.0 --lattice_beam 8.0 --max-active 5000 --acwt 0.9 \
      data/lang_char_test_${lm_suffix} data/test_eval92 $dir/decode_eval92_${lm_suffix} || exit 1;
  done

  # Decoding with the expanded vocabulary
  for lm_suffix in tgpr tg; do
    steps/decode_ctc_lat.sh --cmd "$decode_cmd" --nj 10 --beam 17.0 --lattice_beam 8.0 --max-active 5000 --acwt 0.9 \
      data/lang_char_larger_test_${lm_suffix} data/test_dev93 $dir/decode_dev93_${lm_suffix}_larger || exit 1;
    steps/decode_ctc_lat.sh --cmd "$decode_cmd" --nj 8 --beam 17.0 --lattice_beam 8.0 --max-active 5000 --acwt 0.9 \
      data/lang_char_larger_test_${lm_suffix} data/test_eval92 $dir/decode_eval92_${lm_suffix}_larger || exit 1;
  done
fi
