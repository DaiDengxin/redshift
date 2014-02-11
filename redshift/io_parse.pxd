cdef struct _Parse:
    size_t n_moves
    double score
    size_t* heads
    size_t* labels
    size_t* sbd
    bint* edits
    size_t* moves

cdef struct Sentence:
    size_t id
    size_t length
    size_t* words
    size_t* owords
    size_t* pos
    size_t* alt_pos
    size_t* clusters
    size_t* cprefix4s
    size_t* cprefix6s
    size_t* suffix
    size_t* prefix
    int* parens
    int* quotes
    bint* non_alpha
    bint* oft_upper
    bint* oft_title
    _Parse* parse


cdef Sentence* make_sentence(size_t id_, size_t length,
                            object py_words, object py_tags, size_t vocab_thresh)

cdef int add_parse(Sentence* sent, list ids, list heads, list labels, edits) except -1

cdef free_sent(Sentence* s)

cdef class Sentences:
    cdef object strings
    cdef Sentence** s
    cdef size_t length
    cdef size_t vocab_thresh 
    cdef size_t max_length

    cdef int add(self, Sentence* sent, object words, object tags) except -1
