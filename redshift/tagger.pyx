from redshift._state cimport *
from features.extractor cimport Extractor
from learn.perceptron cimport Perceptron
import index.hashes
cimport index.hashes
from ext.murmurhash cimport MurmurHash64A
from ext.sparsehash cimport *


from redshift.sentence cimport Input, Sentence
from index.lexicon cimport Lexeme


from libc.stdlib cimport malloc, calloc, free
from libc.string cimport memcpy, memset
from libc.stdint cimport uint64_t, int64_t
from libcpp.vector cimport vector 
from libcpp.queue cimport priority_queue
from libcpp.utility cimport pair

cimport cython
from os.path import join as pjoin
import os
import os.path
from os.path import join as pjoin
import random
import shutil
from collections import defaultdict
import json

DEBUG = False


def write_tagger_config(model_dir, beam_width=4, features='basic', feat_thresh=10):
    Config.write(model_dir, beam_width=beam_width, features=features,
                 feat_thresh=feat_thresh)


 
def train(model_dir, list sents, beam_width=4, features='basic', nr_iter=10,
          feat_thresh=10):
    cdef Input sent
    cdef size_t i
    if not os.path.exists(model_dir):
        os.mkdir(model_dir)
    tags = set()
    for sent in sents:
        for i in range(sent.c_sent.n):
            tags.add(sent.tokens[i].tag)
    Config.write(model_dir, beam_width=beam_width, features=features, feat_thresh=feat_thresh,
                 tags=tags)
    tagger = Tagger(model_dir)
    indices = list(range(len(sents)))
    for n in range(nr_iter):
        for i in indices:
            sent = sents[i]
            tagger.train_sent(sent)
        tagger.guide.end_train_iter(n, feat_thresh)
        random.shuffle(indices)
    tagger.guide.end_training(pjoin(model_dir, 'tagger.gz'))
    return tagger


class Config(object):
    def __init__(self, **kwargs):
        for key, value in kwargs.items():
            setattr(self, key, value)

    @classmethod
    def write(cls, model_dir, **kwargs):
        open(pjoin(model_dir, 'tagger_config.json'), 'w').write(json.dumps(kwargs))

    @classmethod
    def read(cls, model_dir):
        return cls(**json.load(open(pjoin(model_dir, 'tagger_config.json'))))


cdef class Tagger:
    def __cinit__(self, model_dir, feat_set="basic", feat_thresh=5, beam_width=4):
        self.cfg = Config.read(model_dir)
        self.extractor = Extractor(basic + clusters + case + orth, [],
                                   bag_of_words=[P1p, P1alt])
        self._features = <uint64_t*>calloc(self.extractor.nr_feat, sizeof(uint64_t))
        self._context = <size_t*>calloc(CONTEXT_SIZE, sizeof(size_t))

        self.feat_thresh = self.cfg.feat_thresh
        self.beam_width = self.cfg.beam_width

        if os.path.exists(pjoin(model_dir, 'pos')):
            index.hashes.load_pos_idx(pjoin(model_dir, 'pos'))
        self.nr_tag = index.hashes.get_nr_pos()
        self.guide = Perceptron(self.nr_tag, pjoin(model_dir, 'tagger.gz'))
        if os.path.exists(pjoin(model_dir, 'tagger.gz')):
            self.guide.load(pjoin(model_dir, 'tagger.gz'),
                            thresh=self.cfg.feat_thresh)
        self.beam_scores = <double**>malloc(sizeof(double*) * self.beam_width)
        for i in range(self.beam_width):
            self.beam_scores[i] = <double*>calloc(self.nr_tag, sizeof(double))

    cpdef int tag(self, Input py_sent) except -1:
        cdef Sentence* sent = py_sent.c_sent
        cdef TaggerBeam beam = TaggerBeam(self.beam_width, sent.n, self.nr_tag)
        cdef size_t p_idx
        cdef TagState* s
        for i in range(sent.n - 1):
            self.fill_beam_scores(beam, sent, i)
            beam.extend_states(self.beam_scores)
        s = <TagState*>beam.beam[0]
        fill_hist(sent.tokens, s, sent.n - 1)

    cdef int fill_beam_scores(self, TaggerBeam beam, Sentence* sent,
                              size_t word_i) except -1:
        for i in range(beam.bsize):
            # At this point, beam.clas is the _last_ prediction, not the prediction
            # for this instance
            fill_context(self._context, sent, beam.parents[i].clas,
                         get_p(beam.parents[i]),
                         beam.parents[i].alt, word_i)
            self.extractor.extract(self._features, self._context)
            self.guide.fill_scores(self._features, self.beam_scores[i])

    cdef int train_sent(self, Input py_sent) except -1:
        cdef Sentence* sent = py_sent.c_sent
        cdef size_t  i, tmp
        cdef TaggerBeam beam = TaggerBeam(self.beam_width, sent.n, self.nr_tag)
        cdef TagState* gold_state = extend_state(NULL, 0, NULL, 0)
        cdef MaxViolnUpd updater = MaxViolnUpd(self.nr_tag)
        for i in range(sent.n - 1):
            gold_state = self.extend_gold(gold_state, sent, i)
            self.fill_beam_scores(beam, sent, i)
            beam.extend_states(self.beam_scores)
            updater.compare(beam.beam[0], gold_state, i)
            self.guide.n_corr += (gold_state.clas == beam.beam[0].clas)
            self.guide.total += 1
        if updater.delta != -1:
            counts = updater.count_feats(self._features, self._context, sent, self.extractor)
            self.guide.batch_update(counts)
        cdef TagState* prev
        while gold_state != NULL:
            prev = gold_state.prev
            free(gold_state)
            gold_state = prev

    cdef TagState* extend_gold(self, TagState* s, Sentence* sent, size_t i) except NULL:
        if i >= 1:
            assert s.clas == sent.tokens[i - 1].tag
        else:
            assert s.clas == 0
        fill_context(self._context, sent, s.clas, get_p(s), s.alt, i)
        self.extractor.extract(self._features, self._context)
        self.guide.fill_scores(self._features, self.guide.scores)
        ext = extend_state(s, sent.tokens[i].tag, self.guide.scores, self.guide.nr_class)
        return ext


cdef class MaxViolnUpd:
    cdef TagState* pred
    cdef TagState* gold
    cdef Sentence* sent
    cdef double delta
    cdef int length
    cdef size_t nr_class
    cdef size_t tmp
    def __cinit__(self, size_t nr_class):
        self.delta = -1
        self.length = -1
        self.nr_class = nr_class

    cdef int compare(self, TagState* pred, TagState* gold, size_t i):
        delta = pred.score - gold.score
        if delta > self.delta:
            self.delta = delta
            self.pred = pred
            self.gold = gold
            self.length = i 

    cdef dict count_feats(self, uint64_t* feats, size_t* context, Sentence* sent,
                          Extractor extractor):
        if self.length == -1:
            return {}
        cdef TagState* g = self.gold
        cdef TagState* p = self.pred
        cdef int i = self.length
        cdef dict counts = {}
        for clas in range(self.nr_class):
            counts[clas] = {} 
        cdef size_t gclas, gprev, gprevprev
        cdef size_t pclas, pprev, prevprev
        while g != NULL and p != NULL and i >= 0:
            gclas = g.clas
            gprev = get_p(g)
            gprevprev = get_pp(g)
            galt = g.alt
            pclas = p.clas
            pprev = get_p(p)
            pprevprev = get_pp(p)
            palt = p.alt
            if gclas == pclas and pprev == gprev and gprevprev == pprevprev:
                g = g.prev
                p = p.prev
                i -= 1
                continue
            fill_context(context, sent, gprev, gprevprev,
                         g.prev.alt if g.prev != NULL else 0, i)
            extractor.extract(feats, context)
            self._inc_feats(counts[gclas], feats, 1.0)
            fill_context(context, sent, pprev, pprevprev,
                         p.prev.alt if p.prev != NULL else 0, i)
            extractor.extract(feats, context)
            self._inc_feats(counts[p.clas], feats, -1.0)
            assert sent.tokens[i].word.norm == context[N0w]
            g = g.prev
            p = p.prev
            i -= 1
        return counts

    cdef int _inc_feats(self, dict counts, uint64_t* feats,
                        double inc) except -1:
        cdef size_t f = 0
        while feats[f] != 0:
            if feats[f] not in counts:
                counts[feats[f]] = 0
            counts[feats[f]] += inc
            f += 1


def print_train_msg(n, n_corr, n_move):
    pc = lambda a, b: '%.1f' % ((float(a) / (b + 1e-100)) * 100)
    move_acc = pc(n_corr, n_move)
    msg = "#%d: Moves %d/%d=%s" % (n, n_corr, n_move, move_acc)
    print msg


cdef enum:
    P1p
    P2p
    P1alt

    N0w
    N0c
    N0c6
    N0c4
    N0pre
    N0suff
    N0title
    N0upper
    N0alpha

    N1w
    N1c
    N1c6
    N1c4
    N1pre
    N1suff
    N1title
    N1upper
    N1alpha

    N2w
    N2c
    N2c6
    N2c4
    N2pre
    N2suff
    N2title
    N2upper
    N2alpha

    N3w
    N3c
    N3c6
    N3c4
    N3pre
    N3suff
    N3title
    N3upper
    N3alpha

    P1w
    P1c
    P1c6
    P1c4
    P1pre
    P1suff
    P1title
    P1upper
    P1alpha

    P2w
    P2c
    P2c6
    P2c4
    P2pre
    P2suff
    P2title
    P2upper
    P2alpha

    CONTEXT_SIZE


basic = (
    (N0w,),
    (N1w,),
    (P1w,),
    (P2w,),
    (P1p,),
    (P2p,),
    (P1p, P2p),
    (P1p, N0w),
    (N0suff,),
    (N1suff,),
    (P1suff,),
    (N2w,),
    (N3w,),
    (P1p, P1alt),
)

case = (
    (N0title,),
    (N0upper,),
    (N0alpha,),
    (N0title, N0suff),
    (N0title, N0upper, N0alpha),
    (P1title,),
    (P1upper,),
    (P1alpha,),
    (N1title,),
    (N1upper,),
    (N1alpha,),
    (P1title, N0title, N1title),
    (P1p, N0title,),
    (P1p, N0upper,),
    (P1p, N0alpha,),
    (P1title, N0w),
    (P1upper, N0w),
    (P1title, N0w, N1title),
    (N0title, N0upper, N0c),
)

orth = (
    (N0pre,),
    (N1pre,),
    (P1pre,),
)

clusters = (
    (N0c,),
    (N0c4,),
    (N0c6,),
    (P1c,),
    (P1c4,),
    (P1c6,),
    (N1c,),
    (N1c4,),
    (N1c6,),
    (N2c,),
    (P1c, N0w),
    (P1p, P1c6, N0w),
    (P1c6, N0w),
    (N0w, N1c),
    (N0w, N1c6),
    (N0w, N1c4),
    (P2c4, P1c4, N0w)
)


cdef inline void fill_token(size_t* context, size_t i, Lexeme* word):
    context[i] = word.norm
    # We've read in the string little-endian, so now we can take & (2**n)-1
    # to get the first n bits of the cluster.
    # e.g. s = "1110010101"
    # s = ''.join(reversed(s))
    # first_4_bits = int(s, 2)
    # print first_4_bits
    # 5
    # print "{0:b}".format(prefix).ljust(4, '0')
    # 1110
    # What we're doing here is picking a number where all bits are 1, e.g.
    # 15 is 1111, 63 is 111111 and doing bitwise AND, so getting all bits in
    # the source that are set to 1.
    context[i+1] = word.cluster
    context[i+2] = word.cluster & 63
    context[i+3] = word.cluster & 15
    context[i+4] = word.prefix
    context[i+5] = word.suffix
    context[i+6] = word.oft_title
    context[i+7] = word.oft_upper
    context[i+8] = word.non_alpha


cdef int fill_context(size_t* context, Sentence* sent, size_t ptag, size_t pptag,
                      size_t p_alt, size_t i):
    for j in range(CONTEXT_SIZE):
        context[j] = 0
    context[P1p] = ptag
    context[P2p] = pptag
    
    fill_token(context, N0w, sent.tokens[i].word)
    fill_token(context, N1w, sent.tokens[i+1].word)
    if (i + 2) < sent.n:
        fill_token(context, N2w, sent.tokens[i+2].word)
    if (i + 3) < sent.n:
        fill_token(context, N3w, sent.tokens[i+3].word)
    if i >= 1:
        fill_token(context, P1w, sent.tokens[i-1].word)
    if i >= 2:
        fill_token(context, P2w, sent.tokens[i-2].word)


cdef class TaggerBeam:
    def __cinit__(self, size_t k, size_t length, nr_tag=None):
        self.nr_class = nr_tag
        self.k = k
        self.t = 0
        self.bsize = 1
        self.is_full = self.bsize >= self.k
        self.seen_states = set()
        self.beam = <TagState**>malloc(k * sizeof(TagState*))
        self.parents = <TagState**>malloc(k * sizeof(TagState*))
        cdef size_t i
        for i in range(k):
            self.parents[i] = extend_state(NULL, 0, NULL, 0)
            self.seen_states.add(<size_t>self.parents[i])

    @cython.cdivision(True)
    cdef int extend_states(self, double** ext_scores) except -1:
        # Former states are now parents, beam will hold the extensions
        cdef size_t i, clas, move_id
        cdef double parent_score, score
        cdef double* scores
        cdef priority_queue[pair[double, size_t]] next_moves
        next_moves = priority_queue[pair[double, size_t]]()
        for i in range(self.bsize):
            scores = ext_scores[i]
            for clas in range(self.nr_class):
                score = self.parents[i].score + scores[clas]
                move_id = (i * self.nr_class) + clas
                next_moves.push(pair[double, size_t](score, move_id))
        cdef pair[double, size_t] data
        # Apply extensions for best continuations
        cdef TagState* s
        cdef TagState* prev
        cdef size_t addr
        cdef dense_hash_map[uint64_t, bint] seen_equivs = dense_hash_map[uint64_t, bint]()
        seen_equivs.set_empty_key(0)
        self.bsize = 0
        while self.bsize < self.k and not next_moves.empty():
            data = next_moves.top()
            i = data.second / self.nr_class
            clas = data.second % self.nr_class
            prev = self.parents[i]
            hashed = (clas * self.nr_class) + prev.clas
            if seen_equivs[hashed]:
                next_moves.pop()
                continue
            seen_equivs[hashed] = 1
            self.beam[self.bsize] = extend_state(prev, clas, ext_scores[i],
                                                 self.nr_class)
            addr = <size_t>self.beam[self.bsize]
            self.seen_states.add(addr)
            next_moves.pop()
            self.bsize += 1
        for i in range(self.bsize):
            self.parents[i] = self.beam[i]
        self.is_full = self.bsize >= self.k
        self.t += 1

    def __dealloc__(self):
        cdef TagState* s
        cdef size_t addr
        for addr in self.seen_states:
            s = <TagState*>addr
            free(s)
        free(self.parents)
        free(self.beam)


cdef TagState* extend_state(TagState* s, size_t clas, double* scores,
                            size_t nr_class):
    cdef double score, alt_score
    cdef size_t alt
    ext = <TagState*>calloc(1, sizeof(TagState))
    ext.prev = s
    ext.clas = clas
    ext.alt = 0
    if s == NULL:
        ext.score = 0
        ext.length = 0
    else:
        ext.score = s.score + scores[clas]
        ext.length = s.length + 1
        alt_score = 1
        for alt in range(nr_class):
            if alt == clas or alt == 0:
                continue
            score = scores[alt]
            if score > alt_score and alt != 0:
                ext.alt = alt
                alt_score = score
    return ext


cdef int fill_hist(Token* tokens, TagState* s, int t) except -1:
    while t >= 1 and s.prev != NULL:
        t -= 1
        tokens[t].tag = s.clas
        s = s.prev

cdef size_t get_p(TagState* s):
    if s.prev == NULL:
        return 0
    else:
        return s.prev.clas


cdef size_t get_pp(TagState* s):
    if s.prev == NULL:
        return 0
    elif s.prev.prev == NULL:
        return 0
    else:
        return s.prev.prev.clas

