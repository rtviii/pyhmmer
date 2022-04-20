# coding: utf-8
# cython: language_level=3, linetrace=True
"""Implementation of a client for the HMMER daemon.

The HMMER daemon is a server daemon provided by HMMER3 to run distributed
search/scan pipelines on one or more worker machines. It is used to
power the `HMMER web server <https://www.ebi.ac.uk/Tools/hmmer/>`_.

This module only provides a client (such as the one in the ``hmmc2``
executable). To run the server, you need a database in the right format
(either a pressed HMM database, or sequences in a special FASTA format).
First launch the master process, and then the worker processes:

.. code:: console

    $ hmmpgmd --master --seqdb db.fasta --cport 51371 --wport 51372
    $ hmmpgmd --worker 127.0.0.1 --wport 51372

You can communicate to the master process after instantiating the
`pyhmmer.daemon.Client` class with the address of the master process and
the port on which it listens for client/server communication::

    >>> client = pyhmmer.daemon.Client("127.0.0.1", 51371)

"""

# --- C imports --------------------------------------------------------------

from cpython.bytearray cimport PyByteArray_AS_STRING

cimport libeasel
cimport libhmmer.hmmpgmd
cimport libhmmer.p7_hit
from libc.stdlib cimport free, realloc
from libc.string cimport memset, memcpy
from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t
from libhmmer.hmmpgmd cimport HMMD_SEARCH_STATUS_SERIAL_SIZE, HMMD_SEARCH_STATUS, HMMD_SEARCH_STATS
from libhmmer.p7_pipeline cimport p7_pipemodes_e, P7_PIPELINE
from libhmmer.p7_hit cimport P7_HIT

from pyhmmer.easel cimport Sequence, Alphabet, MSA
from pyhmmer.errors import UnexpectedError, AllocationError, ServerError
from pyhmmer.plan7 cimport TopHits, Pipeline, HMM


# --- Python imports ---------------------------------------------------------

import io
import socket
import warnings


# --- Cython classes ---------------------------------------------------------

cdef class Client:
    """A `socket`-based client to communicate with a HMMER daemon server.

    This class implements the client-side protocol to query a database with
    a `~pyhmmer.easel.Sequence`, `~pyhmmer.easel.MSA` or `~pyhmmer.plan7.HMM`.
    It must first connect to the server with the `~Client.connect` method::

        >>> client = daemon.Client("127.0.0.1", 51371)
        >>> client.connect()

    Afterwards, the client can be used to run pipelined searches,
    returning a `~pyhmmer.plan7.TopHits`::

        >>> client.search_hmm(thioesterase)
        <pyhmmer.plan7.TopHits object at 0x...>

    Additional keyword arguments can be passed to customize the pipelined
    search. All parameters from `~pyhmmer.plan7.Pipeline` are supported::

        >>> client.search_hmm(thioesterase, F1=0.02, E=1e-5)
        <pyhmmer.plan7.TopHits object at 0x...>

    Hint:
        `Client` implements the context manager protocol, which can be used
        to open and close a connection to the server within a context::

            >>> with daemon.Client() as client:
            ...    client.search_hmm(thioesterase)
            <pyhmmer.plan7.TopHits object at 0x...>

    Caution:
        Hits returned by the server will not have corresponding hit names,
        but only numerical identifiers. It is up to the client user to map
        these to the actual target names, often using an external file or
        database. If the database is small and several queries are made, it
        is feasible to parse the database from the client side to extract
        identifiers of the target HMMs or sequences.

    """

    DEF DEFAULT_ADDRESS = "127.0.0.1"
    DEF DEFAULT_PORT    = 51371

    # --- Magic methods ------------------------------------------------------

    def __init__(
        self,
        str address=DEFAULT_ADDRESS,
        uint16_t port=DEFAULT_PORT,
    ):
        """__init__(self, address="127.0.0.1", port=51371)\n--

        Create a new `Client` connecting to the given HMMEr daemon server.

        Arguments:
            address (`str`): The address of the HMMER daemon server.
            port (`int`): The port over which the HMMER daemon server
                performs client/server communication.

        """
        self.address = address
        self.port = port
        self.socket = socket.socket()

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_value, exc_type, traceback):
        self.close()

    def __repr__(self):
        cdef object ty   = type(self)
        cdef list   args = []
        if self.address != DEFAULT_ADDRESS:
            args.append(self.address)
        if self.port != DEFAULT_PORT:
            args.append(self.port)
        return "{}.{}({})".format(
            ty.__module__,
            ty.__name__,
            "".join(args)
        )

    # --- C Methods ----------------------------------------------------------

    cdef bytearray _recvall(self, size_t message_size):
        """_recvall(self, message_size)\n--

        Receive exactly ``message_size`` bytes from ``self.socket``.

        """
        cdef bytearray buffer = bytearray(message_size)
        cdef object    view   = memoryview(buffer)
        cdef size_t received  = 0
        cdef size_t recv_size = 0
        while received < message_size:
            recv_size = self.socket.recv_into(view)
            if recv_size == 0:
                raise EOFError(f"Expected message of size {message_size}, received {received}")
            received += recv_size
            view = view[recv_size:]
        return buffer

    cdef TopHits _client(
        self,
        object query,
        uint64_t db,
        list ranges,
        Pipeline pli,
        p7_pipemodes_e mode,
    ):
        """_client(self, query, db, pli, mode)\n--

        A generic implementation of the steps to communicate with the server.

        Arguments:
            query (`~easel.Sequence`, `~easel.MSA` or `~plan7.HMM`): A query
                object that can be written to a binary file handle.
            db (`int`): The index of the database to query.
            ranges (`list` of `tuple`): A list of ranges of target sequences
                to query inside the database.
            pli (`~plan7.Pipeline`): A pipeline object used to store generic
                configuration for the search/scan.
            mode (`int`): The pipeline mode marking whether the server should
                be queried in search or scan mode.

        """
        cdef int                status
        cdef HMMD_SEARCH_STATS  search_stats
        cdef HMMD_SEARCH_STATUS search_status

        cdef object             send_buffer
        cdef bytearray          response
        cdef const char*        response_data

        cdef uint32_t           hits_start
        cdef uint32_t           buf_offset    = 0
        cdef TopHits            hits          = TopHits()
        cdef str                options       = "".join(pli.arguments())

        # check ranges argument
        if ranges is not None and len(ranges) < 1:
            raise ValueError("At least one range is needed for the `ranges` argument")
        elif any(len(r) != 2 for r in ranges):
            raise ValueError("`ranges` must be a list of two-element tuples")
        elif not all(isinstance(r[0], int) and isinstance(r[1], int) for r in ranges):
            raise TypeError("`ranges` must be a list where elements are 2-tuples of int")

        # clean memory for data structures allocated on the stack
        memset(&search_stats, 0, sizeof(HMMD_SEARCH_STATS))
        memset(&search_status, 0, sizeof(HMMD_SEARCH_STATUS))
        search_stats.hit_offsets = NULL

        try:
            # serialize the query over the socket
            if mode == p7_pipemodes_e.p7_SEARCH_SEQS:
                if ranges is not None:
                    options = "--seqdb_ranges {} {}".format(
                        ",".join("{}..{}".format(*r) for r in ranges),
                        options
                    )
                self.socket.sendall(f"@--seqdb {db} {options}\n".encode("ascii"))
            else:
                self.socket.sendall(f"@--hmmdb {db} {options}\n".encode("ascii"))
            query.write(self.socket.makefile("wb"))
            self.socket.sendall(b"//")

            # get the search status back
            response = self._recvall(HMMD_SEARCH_STATUS_SERIAL_SIZE)
            status = libhmmer.hmmpgmd.hmmd_search_status_Deserialize(
                <const uint8_t*> PyByteArray_AS_STRING(response),
                &buf_offset,
                &search_status
            )
            if status != libeasel.eslOK:
                raise UnexpectedError(status, "hmmd_search_status_Deserialize")

            # check if error happened
            if search_status.status != libeasel.eslOK:
                error = self.socket.recv(search_status.msg_size)
                raise ServerError(search_status.status, error.decode("utf-8", "replace"))

            # get the response
            response = self._recvall(search_status.msg_size)
            response_data = PyByteArray_AS_STRING(response)

            with nogil:
                # deserialize search_stats
                buf_offset = 0
                status = libhmmer.hmmpgmd.p7_hmmd_search_stats_Deserialize(
                    <const uint8_t*> response_data,
                    &buf_offset,
                    &search_stats
                )
                if status != libeasel.eslOK:
                    raise UnexpectedError(status, "p7_hmmd_search_search_stats_Deserialize")

                # copy input parameters from the pipeline
                memcpy(&hits._pli, pli._pli, sizeof(P7_PIPELINE))

                # copy the search search_stats
                hits._pli.mode                = mode
                hits._pli.nmodels             = search_stats.nmodels
                hits._pli.nseqs               = search_stats.nseqs
                hits._pli.n_past_msv          = search_stats.n_past_msv
                hits._pli.n_past_vit          = search_stats.n_past_vit
                hits._pli.n_past_fwd          = search_stats.n_past_fwd
                hits._pli.Z                   = search_stats.Z
                hits._pli.domZ                = search_stats.domZ
                hits._pli.Z_setby             = search_stats.Z_setby
                hits._pli.domZ_setby          = search_stats.domZ_setby
                hits._th.nreported            = search_stats.nreported
                hits._th.nincluded            = search_stats.nincluded
                hits._th.is_sorted_by_seqidx  = False
                hits._th.is_sorted_by_sortkey = True
                hits._th.N                    = search_stats.nhits

                # reallocate hit arrays
                if search_stats.nhits > 0:
                    hits._th.unsrt = <P7_HIT*> realloc(hits._th.unsrt, search_stats.nhits * sizeof(P7_HIT))
                    if hits._th.unsrt == NULL:
                        raise AllocationError("P7_HIT", sizeof(P7_HIT), search_stats.nhits)
                    hits._th.hit = <P7_HIT**> realloc(hits._th.hit, search_stats.nhits * sizeof(P7_HIT*))
                    if hits._th.hit == NULL:
                        raise AllocationError("P7_HIT*", sizeof(P7_HIT*), search_stats.nhits)

                # deserialize hits
                hits_start = buf_offset
                for i in range(search_stats.nhits):
                    # clean pointers in hit data to force reallocation
                    hits._th.unsrt[i].name = NULL
                    hits._th.unsrt[i].acc  = NULL
                    hits._th.unsrt[i].desc = NULL
                    hits._th.unsrt[i].dcl  = NULL
                    # check buffers match the ones in the search stats
                    if buf_offset - hits_start != search_stats.hit_offsets[i]:
                        with gil:
                            warnings.warn(f"Hit offset {i} did not match expected (expected {search_stats.hit_offsets[i]}, found {buf_offset - hits_start})")
                    # deserialize and record the hit
                    status = libhmmer.p7_hit.p7_hit_Deserialize(
                        <const uint8_t*> response_data,
                        &buf_offset,
                        &hits._th.unsrt[i]
                    )
                    if status != libeasel.eslOK:
                        raise UnexpectedError(status, "p7_hit_Deserialize")
                    hits._th.hit[i] = &hits._th.unsrt[i]

        finally:
            free(search_stats.hit_offsets)

        return hits

    # --- Python Methods -----------------------------------------------------

    def connect(self):
        """connect(self)\n--

        Connect the client to the HMMER daemon server.

        """
        self.socket.connect((self.address, self.port))

    def close(self):
        """close(self)\n--

        Close the connection to the HMMER daemon server.

        """
        self.socket.close()

    def search_seq(
        self,
        Sequence query,
        uint64_t db = 1,
        list ranges = None,
        **options
    ):
        """search_seq(self, query, db=1, ranges=None, **options)\n--

        Search the HMMER daemon database with a query sequence.

        Arguments:
            query (`~pyhmmer.easel.Sequence`): The sequence object to use
                to query the sequence database.
            db (`int`): The index of the sequence database to query.
            ranges (`list` of `tuple`): A list of ranges of target sequences
                to query inside the database.

        Returns:
            `~plan7.TopHits`: The hits found in the sequence database.

        Hint:
            This method corresponds to running ``phmmer`` with the ``query``
            sequence against the sequence database loaded on the server side.

        """
        cdef Alphabet abc = getattr(query, "alphabet", Alphabet.amino())
        cdef Pipeline pli = Pipeline(abc, **options)
        return self._client(query, db, ranges, pli, p7_pipemodes_e.p7_SEARCH_SEQS)

    def search_msa(
        self,
        MSA query,
        uint64_t db = 1,
        list ranges = None,
        **options,
    ):
        """search_msa(self, query, db=1, ranges=None, **options)\n--

        Search the HMMER daemon database with a query MSA.

        Arguments:
            query (`~pyhmmer.easel.MSA`): The multiple sequence alignment
                object to use to query the sequence database.
            db (`int`): The index of the sequence database to query.
            ranges (`list` of `tuple`): A list of ranges of target sequences
                to query inside the database.

        Returns:
            `~plan7.TopHits`: The hits found in the sequence database.

        Hint:
            This method corresponds to running ``phmmer`` with the ``query``
            multiple sequence alignment against the sequence database loaded
            on the server side.

        """
        cdef Alphabet abc = getattr(query, "alphabet", Alphabet.amino())
        cdef Pipeline pli = Pipeline(abc, **options)
        return self._client(query, db, ranges, pli, p7_pipemodes_e.p7_SEARCH_SEQS)

    def search_hmm(
        self,
        HMM query,
        uint64_t db = 1,
        list ranges = None,
        **options
    ):
        """search_hmm(self, query, db=1, ranges=None, **options)\n--

        Search the HMMER daemon database with a query HMM.

        Arguments:
            query (`~pyhmmer.easel.MSA`): The profile HMM object to use to
                query the sequence database.
            db (`int`): The index of the sequence database to query.
            ranges (`list` of `tuple`): A list of ranges of target sequences
                to query inside the database.

        Returns:
            `~plan7.TopHits`: The hits found in the sequence database.

        Hint:
            This method corresponds to running ``hmmsearch`` with the
            ``query`` HMM against the sequence database loaded on the
            server side.

        """
        cdef Pipeline pli = Pipeline(query.alphabet, **options)
        return self._client(query, db, ranges, pli, p7_pipemodes_e.p7_SEARCH_SEQS)

    def scan_seq(self, Sequence query, uint64_t db = 1, **options):
        """scan_seq(self, query, db=1, **options)\n--

        Search the HMMER daemon database with a query sequence.

        Arguments:
            query (`~pyhmmer.easel.Sequence`): The sequence object to use
                to query the HMM database.
            db (`int`): The index of the HMM database to query.

        Returns:
            `~plan7.TopHits`: The hits found in the HMM database.

        Hint:
            This method corresponds to running ``hmmscan`` with the
            ``query`` sequence against the HMM database loaded on the
            server side.

        """
        cdef Alphabet abc = getattr(query, "alphabet", Alphabet.amino())
        cdef Pipeline pli = Pipeline(abc, **options)
        return self._client(query, db, None, pli, p7_pipemodes_e.p7_SCAN_MODELS)
