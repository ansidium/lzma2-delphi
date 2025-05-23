The __Fast LZMA2 Library__ is a lossless high-ratio data compression library based on Igor Pavlov's LZMA2 codec from 7-zip.

Binaries of 7-Zip forks which use the algorithm are available in the [7-Zip-FL2 project], the [7-Zip-zstd project], and the active fork of [p7zip]. The library
is also embedded in a fork of XZ Utils, named [FXZ Utils].

The library uses a parallel buffered radix match-finder and some optimizations from Zstandard to achieve a 20% to 100%
speed gain at the higher levels over the default LZMA2 algorithm used in 7-zip, for a small loss in compression ratio. Speed gains
depend on the nature of the source data. The library also uses some threading, portability, and testing code from Zstandard.

Use of the radix match-finder allows multi-threaded execution employing a simple threading model and with low memory usage. The
library can compress using many threads without dividing the input into large chunks which require the duplication of the
match-finder tables and chains. Extra memory used per thread is typically no more than a few megabytes.

The largest caveat is that the match-finder is a block algorithm, and to achieve about the same ratio as 7-Zip requires double the
dictionary size, which raises the decompression memory usage. By default it uses the same dictionary size as 7-Zip, resulting in
output that is larger by about 1%-5% of the compressed size. A high-compression option is provided to select parameters which
achieve higher compression on smaller dictionaries. The speed/ratio tradeoff is less optimal with this enabled.

Here are the results of an in-memory benchmark using two threads on the [Silesia compression corpus] vs the 7-zip 19.00 LZMA2
encoder. The design goal for the encoder and compression level parameters was to move the line as far as possible toward the top
left of the graph. This provides an optimal speed/ratio tradeoff.

## Building and Using the Delphi Units

Four Delphi units are provided in the repository: `fl2_common.pas`,
`fl2_pool.pas`, `fl2_threading.pas`, and `fl2_helpers.pas`. They allow
applications written in Delphi to call the Fast LZMA2 compression routines.
`fl2_api.pas` wraps the DLL interface and provides simple buffer compression helpers.

The units compile with **RAD Studio 12.3** or later. To use them:

1. Create a Delphi project or open an existing one in RAD Studio.
2. Add the four units to the project or include their directory in the search
   path.
3. Build for the desired Win32 or Win64 target.
4. A ready to run console project is provided under `delphi/`. Open
   `FastLZMA2Test.dproj` to see a minimal example that links the units and
   performs a simple compression/decompression test.
5. Another small project, `FastLZMA2.dproj`, simply prints the library
   version and can be used as a starting point when compiling the units
   natively in Delphi.

These units depend only on the RTL (`System.SysUtils`, `System.Classes` and
`System.SyncObjs`) and require the compiled `fast-lzma2.dll` to be available at
run time. Build the DLL using the provided `Makefile` or Visual Studio solution
and place it on your application's path.

Optional debug information can be enabled by defining `FL2_DEBUG` in the project
options.

## Building the Example Program

The repository ships with a small console application demonstrating the Delphi
bindings.

1. Build `fast-lzma2.dll` using the supplied `Makefile` or the Visual Studio
   solution.
2. Open `delphi/FastLZMA2.dproj` in **RAD Studio 12.3** or later.
3. Choose either the *Win32* or *Win64* target platform and compile.
4. Running the resulting executable prints the FastLZMA2 version string.

## Compiling with RAD Studio 12.3

The Delphi bindings can be built with **RAD Studio 12.3** or a compatible
version. The steps below outline the typical setup:

1. Open `delphi/FastLZMA2Test.dproj` for a working example targeting both Win32
   and Win64.
2. For your own project add the units `fl2_common.pas`,
   `fl2_threading.pas`, and `fl2_pool.pas` along with `fl2_api.pas` and
   `fl2_helpers.pas` to the project or include their directory in the search
   path.
3. Ensure `fast-lzma2.dll` is available at run time (either beside the
   executable or on the system `PATH`).
4. Optionally define `FL2_DEBUG` in the project\'s conditional defines to enable
   additional assertions.
5. Build for the desired Win32 or Win64 target.

The small console project `delphi/FastLZMA2.dproj` is a minimal template that
links the units and prints the FastLZMA2 version string.
