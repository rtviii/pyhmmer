import abc
import io
import itertools
import os
import unittest
import tempfile
import threading
import pkg_resources

import pyhmmer
from pyhmmer.plan7 import Background, Builder, Pipeline, HMMFile, TopHits
from pyhmmer.easel import Alphabet, SequenceFile, DigitalSequence, TextSequence, MSAFile, DigitalMSA
from pyhmmer.errors import AlphabetMismatch


class TestSearchPipeline(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.alphabet = Alphabet.amino()
        with SequenceFile(pkg_resources.resource_filename("tests", "data/seqs/938293.PRJEB85.HG003687.faa")) as f:
            f.set_digital(cls.alphabet)
            cls.references = list(f)

        with MSAFile(pkg_resources.resource_filename("tests", "data/msa/LuxC.sto")) as msa_f:
            msa_f.set_digital(cls.alphabet)
            cls.msa = next(msa_f)

    def test_search_seq_alphabet_mismatch(self):
        pipeline = Pipeline(alphabet=Alphabet.dna())

        # mismatch between pipeline alphabet and database alphabet
        dsq1 = TextSequence(sequence="ATGC").digitize(pipeline.alphabet)
        self.assertRaises(AlphabetMismatch, pipeline.search_seq, dsq1, self.references)

        # mismatch between pipeline alphabet and query alphabet
        dsq2 = TextSequence(sequence="IRGIY").digitize(self.alphabet)
        self.assertRaises(AlphabetMismatch, pipeline.search_seq, dsq2, self.references)

        # check that all ref sequences are checked, not just the first one
        references = self.references.copy()
        references.append(TextSequence(sequence="ATGC").digitize(Alphabet.dna()))
        pipeline = Pipeline(alphabet=self.alphabet)
        self.assertRaises(AlphabetMismatch, pipeline.search_seq, dsq2, references)

    def test_search_msa_alphabet_mismatch(self):
        pipeline = Pipeline(alphabet=Alphabet.dna())

        # mismatch between pipeline alphabet and query alphabet
        self.assertRaises(AlphabetMismatch, pipeline.search_msa, self.msa, self.references)

        # mismatch between pipeline alphabet and database alphabet
        dsq = TextSequence(sequence="ATGC").digitize(pipeline.alphabet)
        msa = DigitalMSA(pipeline.alphabet, sequences=[dsq], name=b"test")
        self.assertRaises(AlphabetMismatch, pipeline.search_msa, msa, self.references)

    def test_search_hmm(self):
        seq = TextSequence(sequence="IRGIYNIIKSVAEDIEIGIIPPSKDHVTISSFKSPRIADT")
        bg = Background(self.alphabet)
        hmm, _, _ = Builder(self.alphabet).build(seq.digitize(self.alphabet), bg)
        pipeline = Pipeline(alphabet=self.alphabet)
        hits = pipeline.search_hmm(hmm, self.references)
        self.assertEqual(len(hits), 1)

    def test_search_seq(self):
        seq = TextSequence(sequence="IRGIYNIIKSVAEDIEIGIIPPSKDHVTISSFKSPRIADT")
        pipeline = Pipeline(alphabet=self.alphabet)
        hits = pipeline.search_seq(seq.digitize(self.alphabet), self.references)
        self.assertEqual(len(hits), 1)

    def test_Z(self):
        seq = TextSequence(sequence="IRGIYNIIKSVAEDIEIGIIPPSKDHVTISSFKSPRIADT")
        bg = Background(self.alphabet)
        hmm, _, _ = Builder(self.alphabet).build(seq.digitize(self.alphabet), bg)

        # when Z is None, use the number of target sequences
        pipeline = Pipeline(alphabet=self.alphabet)
        self.assertIs(pipeline.Z, None)
        hits = pipeline.search_hmm(hmm, self.references[:100])
        self.assertEqual(hits.Z, 100)
        self.assertIs(pipeline.Z, None)
        # clearing the pipeline will keep the Z number as None
        pipeline.clear()
        self.assertIs(pipeline.Z, None)

        # when Z is not None, use the given number
        pipeline = Pipeline(alphabet=self.alphabet, Z=25)
        self.assertEqual(pipeline.Z, 25)
        hits = pipeline.search_hmm(hmm, self.references[:100])
        self.assertEqual(pipeline.Z, 25)
        self.assertEqual(hits.Z, 25)
        # clearing the pipeline will keep the Z number
        pipeline.clear()
        self.assertEqual(pipeline.Z, 25)


class TestScanPipeline(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.alphabet = Alphabet.amino()
        with SequenceFile(pkg_resources.resource_filename("tests", "data/seqs/938293.PRJEB85.HG003687.faa")) as f:
            f.set_digital(cls.alphabet)
            cls.references = list(f)
        with HMMFile(pkg_resources.resource_filename("tests", "data/hmms/txt/t2pks.hmm")) as f:
            cls.hmms = list(f)

    def test_alphabet_mismatch(self):
        pipeline = Pipeline(alphabet=Alphabet.dna())

        # mismatch between pipeline alphabet and query alphabet
        dsq = TextSequence(sequence="IRGIY").digitize(self.alphabet)
        self.assertRaises(AlphabetMismatch, pipeline.scan_seq, dsq, self.hmms)

        # mismatch between pipeline alphabet and database alphabet
        dsq = TextSequence(sequence="ATGC").digitize(pipeline.alphabet)
        self.assertRaises(AlphabetMismatch, pipeline.scan_seq, dsq, self.hmms)

    def test_scan_seq(self):
        seq = next(x for x in self.references if x.name == b"938293.PRJEB85.HG003687_188")
        pipeline = Pipeline(alphabet=self.alphabet)
        hits = pipeline.scan_seq(seq, self.hmms)
        self.assertEqual(len(hits), 6)  # number found with `hmmscan`
