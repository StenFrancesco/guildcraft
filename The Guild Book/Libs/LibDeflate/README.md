# LibDeflate

Upstream: https://github.com/SafeteeWoW/LibDeflate
Version: 1.0.2-release, commit 6831edcaa915154e7769d622e0de72ee5d25a882.
License: zlib (LICENSE.txt and retained source notice).

Altered source: The Guild Book adds an addon-private DecompressProfessionDeflate
entry point, threads an output budget through raw inflation, and checks that
budget before literals, matches and stored blocks allocate output. Status -100
indicates a rejected limit. The budget survives block boundaries and window
flushes. The private inflater also rejects more than 128 DEFLATE blocks with
status -101, checking before each block header or Huffman-table construction.
This bounds zero-output block work independently of output size; the bundled
compressor emits at most two blocks per 64 KiB record. Each decode receives its
own budget. The public LibDeflate API and shared registration version are unchanged.
When an equal/newer shared library already exists, it remains untouched; a local
instance initializes the private inflater, and the normal shared library supplies
compression and channel encoding. The alteration is marked at the source top.
