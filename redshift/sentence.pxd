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


#cdef CParse* init_c_parse(size_t length, list word_ids, list heads, list labels,
#        list edits) except NULL

cdef Sentence* init_c_sent(size_t id_, size_t length, py_words, py_tags,
                             size_t thresh)


cdef int add_parse(Sentence* sent, list word_ids, list heads,
                   list labels, list edits) except -1
#cdef CSentence* init_c_sent(size_t id_, size_t length, py_word_ids, py_words,
#        py_tags, py_heads, py_labels, py_edits) except NULL

cdef free_sent(Sentence* s)


cdef class PySentence:
    cdef size_t id
    cdef Sentence* c_sent
    cdef size_t length
    cdef list tokens
