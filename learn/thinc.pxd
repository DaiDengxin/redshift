from libc.stdint cimport uint64_t
from libc.stdint cimport uint16_t

from cymem.cymem cimport Pool
from trustyc.maps cimport PointerMap


# Typedef numeric types, to make them easier to change and ensure consistency
ctypedef uint64_t F # Feature ID
ctypedef uint16_t C # Class
ctypedef double W # Weight
ctypedef size_t I # Index


# Number of weights in a line. Should be aligned to cache lines.
DEF LINE_SIZE = 7


# A set of weights, to be read in. Start indicates the class that w[0] refers
# to. Subsequent weights go from there.
cdef struct WeightLine:
    C start
    W[LINE_SIZE] line


cdef struct CountLine:
    C start
    I[LINE_SIZE] line


cdef struct TrainFeat:
    WeightLine** weights
    WeightLine** totals
    CountLine** counts
    CountLine** times


cdef class LinearModel:
    cdef I time
    cdef C nr_class
    cdef I n_corr
    cdef I total
    cdef Pool mem
    cdef PointerMap weights
    cdef PointerMap train_weights

    cdef TrainFeat* new_feat(self, F feat_id) except NULL
    cdef I gather_weights(self, WeightLine* w_lines, F* feat_ids, I nr_active) except *
    cdef int score(self, W* inplace, F* features, I nr_active) except -1
    cdef int update(self, dict counts) except -1
