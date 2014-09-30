"""
MALT-style dependency parser
"""
cimport cython
import random
import os.path
from os.path import join as pjoin
import shutil
import json

from libc.string cimport memcpy, memset

from _state cimport *
from sentence cimport Input, Sentence, Token, Step
from cymem.cymem cimport Pool, Address

from beam cimport Beam
from tagger cimport Tagger
from util import Config

from thinc.features.extractor cimport Extractor
import _parse_features
from _parse_features cimport *

import index.hashes
cimport index.hashes

from thinc.ml.learner cimport LinearModel
from thinc.ml.learner cimport W

from libc.stdint cimport uint64_t, int64_t


include "compile_time_options.pxi"
IF TRANSITION_SYSTEM == 'arc_eager':
    from .arc_eager cimport *
ELSE:
    from .arc_hybrid cimport *


VOCAB_SIZE = 1e6
TAG_SET_SIZE = 50


DEBUG = False 
def set_debug(val):
    global DEBUG
    DEBUG = val


def train(train_str, model_dir, n_iter=15, beam_width=8, train_tagger=True,
          feat_set='basic', feat_thresh=10, seed=0,
          use_edit=False, use_break=False, use_filler=False):
    if os.path.exists(model_dir):
        shutil.rmtree(model_dir)
    os.mkdir(model_dir)
    cdef list sents = [Input.from_conll(s) for s in
                       train_str.strip().split('\n\n') if s.strip()]
    left_labels, right_labels, dfl_labels = get_labels(sents)
    Config.write(model_dir, 'config', beam_width=beam_width, features=feat_set,
                 feat_thresh=feat_thresh, seed=seed,
                 left_labels=left_labels, right_labels=right_labels,
                 dfl_labels=dfl_labels, use_break=use_break)
    Config.write(model_dir, 'tagger', beam_width=4, features='basic',
                 feat_thresh=5, tags={})
    parser = Parser(model_dir)
    indices = list(range(len(sents)))
    cdef Input py_sent
    for n in range(n_iter):
        for i in indices:
            py_sent = sents[i]
            parser.tagger.train_sent(py_sent)
            parser.train_sent(py_sent)
        print(parser.guide.end_train_iter(n, feat_thresh) + '\t' +
              parser.tagger.guide.end_train_iter(n, feat_thresh))
        random.shuffle(indices)
    parser.guide.end_training()
    parser.tagger.guide.end_training()
    with open(pjoin(model_dir, 'model.gz'), 'w') as file_:
        parser.guide.dump(file_, freq_thresh=2)
    with open(pjoin(model_dir, 'tagger.gz'), 'w') as file_:
        parser.tagger.guide.dump(file_, freq_thresh=2)
    index.hashes.save_pos_idx(pjoin(model_dir, 'pos'))
    index.hashes.save_label_idx(pjoin(model_dir, 'labels'))
    return parser


def get_labels(sents):
    left_labels = set()
    right_labels = set()
    dfl_labels = set()
    cdef Input sent
    for i, sent in enumerate(sents):
        for j in range(sent.length):
            if sent.c_sent.tokens[j].is_edit:
                dfl_labels.add(sent.c_sent.tokens[j].label)
            elif sent.c_sent.tokens[j].head > j:
                left_labels.add(sent.c_sent.tokens[j].label)
            else:
                right_labels.add(sent.c_sent.tokens[j].label)
    return list(sorted(left_labels)), list(sorted(right_labels)), list(sorted(dfl_labels))


def get_templates(feats_str):
    match_feats = []
    # This value comes out of compile_time_options.pxi
    IF TRANSITION_SYSTEM == 'arc_eager':
        templates = _parse_features.arc_eager
    ELSE:
        templates = _parse_features.arc_hybrid
    if 'disfl' in feats_str:
        templates += _parse_features.disfl
        templates += _parse_features.new_disfl
        templates += _parse_features.suffix_disfl
        templates += _parse_features.extra_labels
        templates += _parse_features.clusters
        templates += _parse_features.edges
        templates += _parse_features.prev_next
        match_feats = _parse_features.match_templates()
    elif 'clusters' in feats_str:
        templates += _parse_features.clusters
    if 'bitags' in feats_str:
        templates += _parse_features.pos_bigrams()
    return templates, match_feats


cdef class Parser:
    cdef object cfg
    cdef Pool _pool
    cdef Extractor extractor
    cdef LinearModel guide
    cdef Tagger tagger
    cdef size_t beam_width
    cdef int feat_thresh
    cdef Transition* moves
    cdef uint64_t* _features
    cdef size_t* _context
    cdef size_t nr_moves

    def __cinit__(self, model_dir):
        assert os.path.exists(model_dir) and os.path.isdir(model_dir)
        self.cfg = Config.read(model_dir, 'config')
        self.extractor = Extractor(*get_templates(self.cfg.features))
        self._pool = Pool()
        self._features = <uint64_t*>self._pool.alloc(self.extractor.nr_feat, sizeof(uint64_t))
        self._context = <size_t*>self._pool.alloc(_parse_features.context_size(), sizeof(size_t))

        self.feat_thresh = self.cfg.feat_thresh
        self.beam_width = self.cfg.beam_width
 
        if os.path.exists(pjoin(model_dir, 'labels')):
            index.hashes.load_label_idx(pjoin(model_dir, 'labels'))
        self.nr_moves = get_nr_moves(self.cfg.left_labels, self.cfg.right_labels,
                                     self.cfg.dfl_labels, self.cfg.use_break)
        self.moves = <Transition*>self._pool.alloc(self.nr_moves, sizeof(Transition))
        fill_moves(self.cfg.left_labels, self.cfg.right_labels, self.cfg.dfl_labels,
                   self.cfg.use_break, self.moves)
        
        self.guide = LinearModel(self.nr_moves, self.extractor.nr_feat)
        if os.path.exists(pjoin(model_dir, 'model.gz')):
            with open(pjoin(model_dir, 'model.gz')) as file_:
                self.guide.load(file_)
        if os.path.exists(pjoin(model_dir, 'pos')):
            index.hashes.load_pos_idx(pjoin(model_dir, 'pos'))
        self.tagger = Tagger(model_dir)

    cpdef int parse(self, Input py_sent) except -1:
        cdef Sentence* sent = py_sent.c_sent
        cdef size_t p_idx, i
        if self.tagger:
            self.tagger.tag(py_sent)
        cdef Beam beam = Beam(self.beam_width, <size_t>self.moves, self.nr_moves,
                              py_sent)
        self.guide.cache.flush()
        while not beam.is_finished:
            for i in range(beam.bsize):
                if not is_final(beam.beam[i]):
                    self._predict(beam.beam[i], beam.moves[i])
                # The False flag tells it to allow non-gold predictions
                beam.enqueue(i, False)
            beam.extend()
        beam.fill_parse(sent.tokens)
        py_sent.segment()
        sent.score = beam.beam[0].score

    cdef int _predict(self, State* s, Transition* classes) except -1:
        if is_final(s):
            return 0
        cdef bint cache_hit = False
        fill_slots(s)
        scores = self.guide.cache.lookup(sizeof(SlotTokens), &s.slots, &cache_hit)
        if not cache_hit:
            fill_context(self._context, &s.slots, s.parse)
            nr_active = self.extractor.extract(self._features, self._context)
            self.guide.score(scores, self._features, nr_active)
        fill_valid(s, classes, self.nr_moves)
        cdef size_t i
        for i in range(self.nr_moves):
            classes[i].score = scores[i]

    cdef int train_sent(self, Input py_sent) except -1:
        cdef size_t i
        cdef Transition[1000] g_hist
        cdef Transition[1000] p_hist
        cdef Sentence* sent = py_sent.c_sent
        cdef Address tags_mem = Address(sent.n, sizeof(size_t))
        cdef size_t* gold_tags = <size_t*>tags_mem.addr
        for i in range(sent.n):
            gold_tags[i] = sent.tokens[i].tag
        if self.tagger:
            self.tagger.tag(py_sent)
        g_beam = Beam(self.beam_width, <size_t>self.moves, self.nr_moves, py_sent)
        p_beam = Beam(self.beam_width, <size_t>self.moves, self.nr_moves, py_sent)
        cdef Token* gold_parse = sent.tokens
        cdef double delta = 0
        cdef double max_violn = -1
        cdef size_t pt = 0
        cdef size_t gt = 0
        cdef State* p
        cdef State* g
        cdef Transition* moves
        words = py_sent.words
        self.guide.cache.flush()
        while not p_beam.is_finished and not g_beam.is_finished:
            for i in range(p_beam.bsize):
                self._predict(p_beam.beam[i], p_beam.moves[i])
                # Fill costs so we can see whether the prediction is gold-standard
                fill_costs(p_beam.beam[i], p_beam.moves[i], self.nr_moves, gold_parse)
                # The False flag tells it to allow non-gold predictions
                p_beam.enqueue(i, False)
            p_beam.extend()
            for i in range(g_beam.bsize):
                g = g_beam.beam[i]
                moves = g_beam.moves[i]
                self._predict(g, moves)
                fill_costs(g, moves, self.nr_moves, gold_parse)
                g_beam.enqueue(i, True)
            g_beam.extend()
            g = g_beam.beam[0]; p = p_beam.beam[0] 
            delta = p.score - g.score
            if delta > max_violn and p.cost >= 1:
                max_violn = delta
                pt = p.m
                gt = g.m
                memcpy(p_hist, p.history, pt * sizeof(Transition))
                memcpy(g_hist, g.history, gt * sizeof(Transition))
        if max_violn >= 0:
            counted = self._count_feats(sent, pt, gt, p_hist, g_hist)
            self.guide.update(counted)
        else:
            self.guide.time += 1
        for i in range(sent.n):
            sent.tokens[i].tag = gold_tags[i]
        self.guide.n_corr += p_beam.beam[0].cost == 0
        self.guide.total += 1

    cdef dict _count_feats(self, Sentence* sent, size_t pt, size_t gt,
                           Transition* phist, Transition* ghist):
        cdef size_t d, i, f
        cdef uint64_t* feats
        cdef size_t clas
        cdef Pool tmp_pool = Pool()
        cdef State* gold_state = init_state(sent, tmp_pool)
        cdef State* pred_state = init_state(sent, tmp_pool)
        cdef dict counts = {}
        for clas in range(self.nr_moves):
            counts[clas] = {}
        cdef bint seen_diff = False
        for i in range(max((pt, gt))):
            # Find where the states diverge
            if not seen_diff and ghist[i].clas == phist[i].clas:
                transition(&ghist[i], gold_state)
                transition(&phist[i], pred_state)
                continue
            seen_diff = True
            if i < gt:
                fill_slots(gold_state)
                fill_context(self._context, &gold_state.slots, gold_state.parse)
                self.extractor.extract(self._features, self._context)
                self.extractor.count(counts[ghist[i].clas], self._features, 1.0)
                transition(&ghist[i], gold_state)
            if i < pt:
                fill_slots(pred_state)
                fill_context(self._context, &pred_state.slots, pred_state.parse)
                self.extractor.extract(self._features, self._context)
                self.extractor.count(counts[phist[i].clas], self._features, -1.0)
                transition(&phist[i], pred_state)
        return counts
